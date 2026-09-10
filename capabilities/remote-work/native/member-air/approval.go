package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/term"
)

const approvalKeyIterations = 310_000
const approvalKeyAAD = "two-head-wu-owner-approval-key-v1"
const approvalScheme = "TWO-HEAD-WU-OWNER-APPROVAL-V1"
const approvalKeyScheme = "TWO-HEAD-WU-OWNER-APPROVAL-KEY-V1"
const ownerConfirmationCode = "    "

var capabilityIDPattern = regexp.MustCompile(`^[a-z][a-z0-9-]*:[a-z][a-z0-9-]*$`)

type encryptedApprovalKey struct {
	SchemaVersion       int    `json:"schema_version"`
	KDF                 string `json:"kdf"`
	Iterations          int    `json:"iterations"`
	SaltBase64          string `json:"salt_base64"`
	Cipher              string `json:"cipher"`
	NonceBase64         string `json:"nonce_base64"`
	CiphertextBase64    string `json:"ciphertext_base64"`
	PublicKeySPKIBase64 string `json:"public_key_spki_base64"`
}

type approvalEnvelope struct {
	InputSHA256     string `json:"input_sha256"`
	ExpiresAt       int64  `json:"expires_at"`
	Nonce           string `json:"nonce"`
	SignatureBase64 string `json:"signature_base64"`
}

type capabilityDirectory struct {
	Catalog         json.RawMessage `json:"catalog"`
	EffectiveGrants []struct {
		CapabilityID string `json:"capability_id"`
	} `json:"effective_grants"`
}

func pbkdf2SHA256(password, salt []byte, iterations, size int) ([]byte, error) {
	if iterations < 100_000 || iterations > 2_000_000 || size < 1 || size > 64 || len(salt) < 16 {
		return nil, errors.New("approval key KDF parameters are invalid")
	}
	hashLength := sha256.Size
	blocks := (size + hashLength - 1) / hashLength
	derived := make([]byte, 0, blocks*hashLength)
	for block := 1; block <= blocks; block++ {
		mac := hmac.New(sha256.New, password)
		mac.Write(salt)
		var counter [4]byte
		binary.BigEndian.PutUint32(counter[:], uint32(block))
		mac.Write(counter[:])
		u := mac.Sum(nil)
		t := append([]byte(nil), u...)
		for round := 1; round < iterations; round++ {
			mac = hmac.New(sha256.New, password)
			mac.Write(u)
			u = mac.Sum(nil)
			for index := range t {
				t[index] ^= u[index]
			}
		}
		derived = append(derived, t...)
	}
	return derived[:size], nil
}

func encryptApprovalPrivateKey(password []byte) (encryptedApprovalKey, *ecdsa.PrivateKey, error) {
	if !hmac.Equal(password, []byte(ownerConfirmationCode)) {
		return encryptedApprovalKey{}, nil, errors.New("owner confirmation code must be exactly four spaces")
	}
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return encryptedApprovalKey{}, nil, errors.New("cannot create approval key")
	}
	privateDER, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return encryptedApprovalKey{}, nil, errors.New("cannot encode approval key")
	}
	publicDER, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
	if err != nil {
		return encryptedApprovalKey{}, nil, errors.New("cannot encode approval public key")
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return encryptedApprovalKey{}, nil, errors.New("cannot create approval key salt")
	}
	key, err := pbkdf2SHA256(password, salt, approvalKeyIterations, 32)
	if err != nil {
		return encryptedApprovalKey{}, nil, err
	}
	defer wipe(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return encryptedApprovalKey{}, nil, errors.New("cannot initialize approval encryption")
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return encryptedApprovalKey{}, nil, errors.New("cannot initialize approval encryption")
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return encryptedApprovalKey{}, nil, errors.New("cannot create approval encryption nonce")
	}
	ciphertext := gcm.Seal(nil, nonce, privateDER, []byte(approvalKeyAAD))
	wipe(privateDER)
	return encryptedApprovalKey{
		SchemaVersion:       1,
		KDF:                 "pbkdf2-hmac-sha256",
		Iterations:          approvalKeyIterations,
		SaltBase64:          base64.StdEncoding.EncodeToString(salt),
		Cipher:              "aes-256-gcm",
		NonceBase64:         base64.StdEncoding.EncodeToString(nonce),
		CiphertextBase64:    base64.StdEncoding.EncodeToString(ciphertext),
		PublicKeySPKIBase64: base64.StdEncoding.EncodeToString(publicDER),
	}, privateKey, nil
}

func decryptApprovalPrivateKey(value encryptedApprovalKey, password []byte) (*ecdsa.PrivateKey, error) {
	if value.SchemaVersion != 1 || value.KDF != "pbkdf2-hmac-sha256" || value.Cipher != "aes-256-gcm" ||
		value.Iterations < 100_000 || value.Iterations > 2_000_000 {
		return nil, errors.New("approval key file is invalid")
	}
	salt, err := decodeCanonicalBase64(value.SaltBase64, 16, 16)
	if err != nil {
		return nil, errors.New("approval key file is invalid")
	}
	nonce, err := decodeCanonicalBase64(value.NonceBase64, 12, 32)
	if err != nil {
		return nil, errors.New("approval key file is invalid")
	}
	ciphertext, err := decodeCanonicalBase64(value.CiphertextBase64, 32, 4096)
	if err != nil {
		return nil, errors.New("approval key file is invalid")
	}
	publicDER, err := decodeCanonicalBase64(value.PublicKeySPKIBase64, 91, 91)
	if err != nil {
		return nil, errors.New("approval key file is invalid")
	}
	key, err := pbkdf2SHA256(password, salt, value.Iterations, 32)
	if err != nil {
		return nil, err
	}
	defer wipe(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, errors.New("owner confirmation code or approval key file is invalid")
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil || len(nonce) != gcm.NonceSize() {
		return nil, errors.New("approval key file is invalid")
	}
	privateDER, err := gcm.Open(nil, nonce, ciphertext, []byte(approvalKeyAAD))
	if err != nil {
		return nil, errors.New("owner confirmation code or approval key file is invalid")
	}
	defer wipe(privateDER)
	parsed, err := x509.ParsePKCS8PrivateKey(privateDER)
	privateKey, ok := parsed.(*ecdsa.PrivateKey)
	if err != nil || !ok || privateKey.Curve != elliptic.P256() {
		return nil, errors.New("approval key file is invalid")
	}
	actualPublic, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
	if err != nil || !hmac.Equal(actualPublic, publicDER) {
		return nil, errors.New("owner confirmation code or approval key file is invalid")
	}
	return privateKey, nil
}

func decodeCanonicalBase64(value string, minimum, maximum int) ([]byte, error) {
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err != nil || len(decoded) < minimum || len(decoded) > maximum || base64.StdEncoding.EncodeToString(decoded) != value {
		return nil, errors.New("invalid Base64")
	}
	return decoded, nil
}

func wipe(value []byte) {
	for index := range value {
		value[index] = 0
	}
}

func saveEncryptedApprovalKey(path string, value encryptedApprovalKey) error {
	if _, err := os.Lstat(path); err == nil || !os.IsNotExist(err) {
		return errors.New("approval key already exists")
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return errors.New("cannot encode approval key")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil || os.Chmod(filepath.Dir(path), 0700) != nil {
		return errors.New("cannot protect approval key directory")
	}
	return atomicFile(path, append(data, '\n'))
}

func loadEncryptedApprovalKey(path string) (encryptedApprovalKey, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0077 != 0 {
		return encryptedApprovalKey{}, errors.New("approval key file is unavailable or not private")
	}
	data, err := os.ReadFile(path)
	if err != nil || len(data) > 16*1024 {
		return encryptedApprovalKey{}, errors.New("approval key file is unavailable or invalid")
	}
	var value encryptedApprovalKey
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&value) != nil || decoder.Decode(&struct{}{}) == nil {
		return encryptedApprovalKey{}, errors.New("approval key file is invalid")
	}
	return value, nil
}

func readPassword(prompt string) ([]byte, error) {
	descriptor := int(os.Stdin.Fd())
	if !term.IsTerminal(descriptor) {
		return nil, errors.New("owner confirmation code requires an interactive terminal")
	}
	fmt.Fprint(os.Stderr, prompt)
	value, err := term.ReadPassword(descriptor)
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return nil, errors.New("cannot read owner confirmation code")
	}
	if !hmac.Equal(value, []byte(ownerConfirmationCode)) {
		wipe(value)
		return nil, errors.New("owner confirmation code must be exactly four spaces")
	}
	return value, nil
}

func approvalKeyPath(configPath string) string {
	return filepath.Join(filepath.Dir(configPath), "approval-key.json")
}

func approvalPublicKey(privateKey *ecdsa.PrivateKey) (string, []byte, error) {
	publicDER, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
	if err != nil {
		return "", nil, errors.New("cannot encode approval public key")
	}
	return base64.StdEncoding.EncodeToString(publicDER), publicDER, nil
}

func signApproval(privateKey *ecdsa.PrivateKey, canonical []byte) (string, error) {
	digest := sha256.Sum256(canonical)
	signature, err := ecdsa.SignASN1(rand.Reader, privateKey, digest[:])
	if err != nil {
		return "", errors.New("cannot sign owner approval")
	}
	return base64.StdEncoding.EncodeToString(signature), nil
}

func (c *memberClient) registerApprovalKey(privateKey *ecdsa.PrivateKey) (string, error) {
	identity, err := c.diagnose()
	if err != nil || identity.User.Role != "owner" {
		return "", errors.New("approval keys are available only on the registered owner Air")
	}
	publicText, publicDER, err := approvalPublicKey(privateKey)
	if err != nil {
		return "", err
	}
	canonical := strings.Join([]string{approvalKeyScheme, c.config.UserID, c.config.DeviceID, publicText}, "\n")
	signature, err := signApproval(privateKey, []byte(canonical))
	if err != nil {
		return "", err
	}
	body, _ := json.Marshal(map[string]string{
		"public_key_spki_base64": publicText,
		"proof_signature_base64": signature,
	})
	response, err := c.request(http.MethodPost, "/approval-key", body)
	if err != nil {
		return "", err
	}
	var result struct {
		SchemaVersion   int    `json:"schema_version"`
		Registered      bool   `json:"registered"`
		PublicKeySHA256 string `json:"public_key_sha256"`
	}
	if err := decodeJSON(response, &result); err != nil {
		return "", err
	}
	digest := sha256.Sum256(publicDER)
	expected := hex.EncodeToString(digest[:])
	if result.SchemaVersion != 1 || !result.Registered || result.PublicKeySHA256 != expected {
		return "", errors.New("relay did not confirm the owner approval key")
	}
	return expected, nil
}

func (c *memberClient) approvalKeyStatus() (bool, string, error) {
	response, err := c.request(http.MethodGet, "/approval-key", nil)
	if err != nil {
		return false, "", err
	}
	var result struct {
		SchemaVersion   int     `json:"schema_version"`
		Registered      bool    `json:"registered"`
		PublicKeySHA256 *string `json:"public_key_sha256"`
	}
	if err := decodeJSON(response, &result); err != nil || result.SchemaVersion != 1 {
		return false, "", errors.New("relay returned invalid approval key status")
	}
	digest := ""
	if result.PublicKeySHA256 != nil {
		digest = *result.PublicKeySHA256
	}
	if result.Registered && !hexPattern.MatchString(digest) {
		return false, "", errors.New("relay returned invalid approval key status")
	}
	return result.Registered, digest, nil
}

func canonicalCapabilityInput(value map[string]any) ([]byte, error) {
	var output bytes.Buffer
	encoder := json.NewEncoder(&output)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, errors.New("cannot encode capability input")
	}
	return bytes.TrimSuffix(output.Bytes(), []byte("\n")), nil
}

func decodeCapabilityInput(value string) (map[string]any, error) {
	if len(value) == 0 || len(value) > 16*1024 || !utf8.ValidString(value) {
		return nil, errors.New("capability input must be a bounded JSON object")
	}
	decoder := json.NewDecoder(strings.NewReader(value))
	decoder.UseNumber()
	var input map[string]any
	if decoder.Decode(&input) != nil || input == nil || decoder.Decode(&struct{}{}) == nil {
		return nil, errors.New("capability input must be one JSON object")
	}
	canonical, err := canonicalCapabilityInput(input)
	if err != nil || rejectMemberSecretBytes(canonical) != nil {
		return nil, errors.New("capability input failed local secret DLP")
	}
	return input, nil
}

func (c *memberClient) capabilityConfirmation(capabilityID string) (string, error) {
	response, err := c.request(http.MethodGet, "/capabilities", nil)
	if err != nil {
		return "", err
	}
	var directory capabilityDirectory
	if err := decodeJSON(response, &directory); err != nil {
		return "", err
	}
	_, capabilities, err := verifyCapabilityManifest(directory.Catalog, embeddedReleasePublicKey)
	if err != nil {
		return "", errors.New("relay returned an invalid signed Air capability directory")
	}
	granted := false
	for _, grant := range directory.EffectiveGrants {
		if grant.CapabilityID == capabilityID {
			granted = true
		}
	}
	for _, capability := range capabilities {
		if capability.ID != capabilityID {
			continue
		}
		if capability.Status != "active" || !granted {
			return "", errors.New("capability is unavailable or not granted")
		}
		confirmation := capability.Confirmation
		if confirmation == "" {
			confirmation = "none"
		}
		if confirmation != "none" && confirmation != "owner-password" {
			return "", errors.New("capability confirmation policy is invalid")
		}
		return confirmation, nil
	}
	return "", errors.New("capability is unavailable or not granted")
}

func buildApprovalEnvelope(
	privateKey *ecdsa.PrivateKey,
	value config,
	requestID, capabilityID string,
	input map[string]any,
	now time.Time,
	nonce string,
) (approvalEnvelope, error) {
	canonicalInput, err := canonicalCapabilityInput(input)
	if err != nil {
		return approvalEnvelope{}, err
	}
	inputDigest := sha256.Sum256(canonicalInput)
	inputSHA := hex.EncodeToString(inputDigest[:])
	expiresAt := now.Unix() + 120
	if !regexp.MustCompile(`^[a-f0-9]{32}$`).MatchString(nonce) {
		return approvalEnvelope{}, errors.New("cannot create approval nonce")
	}
	canonical := strings.Join([]string{
		approvalScheme,
		value.UserID,
		value.DeviceID,
		requestID,
		capabilityID,
		inputSHA,
		fmt.Sprintf("%d", expiresAt),
		nonce,
	}, "\n")
	signature, err := signApproval(privateKey, []byte(canonical))
	if err != nil {
		return approvalEnvelope{}, err
	}
	return approvalEnvelope{
		InputSHA256: inputSHA, ExpiresAt: expiresAt, Nonce: nonce, SignatureBase64: signature,
	}, nil
}

func (c *memberClient) invokeCapability(
	capabilityID, requestID, confirmation string,
	input map[string]any,
	privateKey *ecdsa.PrivateKey,
) (memberJob, error) {
	if !capabilityIDPattern.MatchString(capabilityID) || !regexp.MustCompile(`^call-[a-f0-9]{24}$`).MatchString(requestID) {
		return memberJob{}, errors.New("capability target or request id is invalid")
	}
	if confirmation != "none" && confirmation != "owner-password" {
		return memberJob{}, errors.New("capability confirmation policy is invalid")
	}
	payload := map[string]any{"request_id": requestID, "capability_id": capabilityID, "input": input}
	if confirmation == "owner-password" {
		if privateKey == nil {
			return memberJob{}, errors.New("capability requires the owner confirmation code")
		}
		nonce, err := c.nonce()
		if err != nil {
			return memberJob{}, errors.New("cannot create approval nonce")
		}
		approval, err := buildApprovalEnvelope(privateKey, c.config, requestID, capabilityID, input, c.now(), nonce)
		if err != nil {
			return memberJob{}, err
		}
		payload["approval"] = approval
	}
	body, _ := json.Marshal(payload)
	response, err := c.request(http.MethodPost, "/calls", body)
	if err != nil {
		return memberJob{}, err
	}
	var envelope struct {
		Job memberJob `json:"job"`
	}
	if err := decodeJSON(response, &envelope); err != nil {
		return memberJob{}, err
	}
	if !jobPattern.MatchString(envelope.Job.ID) || envelope.Job.State != "queued" {
		return memberJob{}, errors.New("relay did not queue the capability call")
	}
	return envelope.Job, nil
}

func parseInvokeArguments(arguments []string) (string, string, string, error) {
	values := map[string]string{}
	for len(arguments) > 0 {
		if len(arguments) < 2 || (arguments[0] != "--capability" && arguments[0] != "--input-json" && arguments[0] != "--request-id") {
			return "", "", "", errors.New("usage: two-head-wu-air invoke --capability ID --input-json JSON [--request-id CALL_ID]")
		}
		if _, exists := values[arguments[0]]; exists || arguments[1] == "" {
			return "", "", "", errors.New("duplicate or empty invoke option")
		}
		values[arguments[0]] = arguments[1]
		arguments = arguments[2:]
	}
	if !capabilityIDPattern.MatchString(values["--capability"]) || values["--input-json"] == "" {
		return "", "", "", errors.New("invoke requires a capability id and JSON input")
	}
	requestID := values["--request-id"]
	if requestID == "" {
		var err error
		requestID, err = requestIDFromRandom()
		if err != nil {
			return "", "", "", err
		}
	}
	return values["--capability"], values["--input-json"], requestID, nil
}
