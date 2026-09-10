package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"mime"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

const authScheme = "TWO-HEAD-WU-MEMBER-V2"
const maximumCapsuleBytes = 50 * 1024 * 1024
const maximumCapsuleEntries = 10_000
const airUsage = "usage: two-head-wu-air enroll ... | diagnose | modules | module-pull MODULE_ID | invoke ... | approval-init | approval-register | approval-status | submit ... | interactions JOB_ID | reply JOB_ID ASK_ID accept|decline|cancel | answer JOB_ID ASK_ID -- ANSWER | fetch JOB_ID"

var (
	userPattern           = regexp.MustCompile(`^usr-[a-z0-9][a-z0-9-]{7,63}$`)
	devicePattern         = regexp.MustCompile(`^dev-[a-z0-9][a-z0-9-]{7,95}$`)
	jobPattern            = regexp.MustCompile(`^job-[a-z0-9][a-z0-9-]{7,95}$`)
	interactionPattern    = regexp.MustCompile(`^ask-[a-f0-9]{16}$`)
	codexBindingPattern   = regexp.MustCompile(`^cdx-[a-z0-9][a-z0-9-]{7,95}$`)
	contentPattern        = regexp.MustCompile(`^content-[a-z0-9][a-z0-9-]{7,63}$`)
	hexPattern            = regexp.MustCompile(`^[a-f0-9]{64}$`)
	pairPattern           = regexp.MustCompile(`^pair-[A-Za-z0-9_-]{43}$`)
	envNamePattern        = regexp.MustCompile(`^[A-Z][A-Z0-9_]{0,63}$`)
	credentialNamePattern = regexp.MustCompile(`^(credentials?|secrets?|tokens?)(\.|$)`)
	memberSecretPatterns  = []*regexp.Regexp{
		regexp.MustCompile(`CANARY_DO_NOT_EXPORT_`),
		regexp.MustCompile(`-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----`),
		regexp.MustCompile(`\bAKIA[0-9A-Z]{16}\b`),
		regexp.MustCompile(`\bgh[pousr]_[A-Za-z0-9]{20,}\b`),
		regexp.MustCompile(`\bsk-[A-Za-z0-9_-]{20,}\b`),
		regexp.MustCompile(`\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\b`),
	}
)

type config struct {
	SchemaVersion int    `json:"schema_version"`
	Endpoint      string `json:"endpoint"`
	UserID        string `json:"user_id"`
	DeviceID      string `json:"device_id"`
	ReviewRoot    string `json:"review_root,omitempty"`
}

type signer interface {
	Sign([]byte) (string, error)
}

type hardwareKey interface {
	signer
	Create() (keyMaterial, error)
}

type keyMaterial struct {
	Provider            string `json:"provider"`
	PublicKeySPKIBase64 string `json:"public_key_spki_base64"`
}

type nativeSigner struct {
	programDir string
}

func (s nativeSigner) command(arguments ...string) *exec.Cmd {
	if runtime.GOOS == "darwin" {
		return exec.Command(filepath.Join(s.programDir, "member-key"), arguments...)
	}
	if runtime.GOOS == "windows" {
		base := []string{"-NoProfile", "-NonInteractive", "-File", filepath.Join(s.programDir, "MemberKey.ps1")}
		return exec.Command("powershell.exe", append(base, arguments...)...)
	}
	return nil
}

func (s nativeSigner) Create() (keyMaterial, error) {
	command := s.command("create")
	if command == nil {
		return keyMaterial{}, errors.New("Air supports only macOS and Windows")
	}
	command.Env = minimalEnvironment()
	output, err := command.Output()
	if err != nil {
		return keyMaterial{}, errors.New("hardware key creation failed")
	}
	var result keyMaterial
	_, expectedProvider, platformError := platformIdentity()
	if json.Unmarshal(output, &result) != nil || platformError != nil || validateKeyMaterial(result, expectedProvider) != nil {
		return keyMaterial{}, errors.New("hardware key helper returned invalid public key")
	}
	return result, nil
}

func (s nativeSigner) Sign(message []byte) (string, error) {
	encoded := base64.StdEncoding.EncodeToString(message)
	command := s.command("sign", "--input-base64", encoded)
	if runtime.GOOS == "windows" {
		command = s.command("sign", "-InputBase64", encoded)
	}
	if command == nil {
		return "", errors.New("Air supports only macOS and Windows")
	}
	command.Env = minimalEnvironment()
	output, err := command.Output()
	if err != nil {
		return "", errors.New("hardware signing failed")
	}
	var result struct {
		Signature string `json:"signature_base64"`
	}
	if json.Unmarshal(output, &result) != nil || result.Signature == "" {
		return "", errors.New("hardware signer returned invalid output")
	}
	if _, err := base64.StdEncoding.DecodeString(result.Signature); err != nil {
		return "", errors.New("hardware signer returned invalid signature")
	}
	return result.Signature, nil
}

func validateKeyMaterial(material keyMaterial, expectedProvider string) error {
	if expectedProvider == "" || material.Provider != expectedProvider {
		return errors.New("hardware key provider does not match this platform")
	}
	der, err := base64.StdEncoding.DecodeString(material.PublicKeySPKIBase64)
	if err != nil || base64.StdEncoding.EncodeToString(der) != material.PublicKeySPKIBase64 {
		return errors.New("hardware public key is not canonical Base64")
	}
	parsed, err := x509.ParsePKIXPublicKey(der)
	key, ok := parsed.(*ecdsa.PublicKey)
	if err != nil || !ok || key.Curve != elliptic.P256() {
		return errors.New("hardware public key is not P-256 SPKI")
	}
	return nil
}

func minimalEnvironment() []string {
	allowed := []string{"PATH", "SystemRoot", "WINDIR"}
	result := make([]string, 0, len(allowed))
	for _, name := range allowed {
		if value, ok := os.LookupEnv(name); ok {
			result = append(result, name+"="+value)
		}
	}
	return result
}

type memberClient struct {
	config    config
	signer    signer
	http      *http.Client
	allowHTTP bool
	now       func() time.Time
	nonce     func() (string, error)
}

type memberJob struct {
	ID              string   `json:"id"`
	State           string   `json:"state"`
	ContentLeaseIDs []string `json:"content_lease_ids"`
}

type interactionReply struct {
	Decision string `json:"decision"`
	Answer   string `json:"answer,omitempty"`
}

type memberInteraction struct {
	SchemaVersion    int               `json:"schema_version"`
	ID               string            `json:"id"`
	UserID           string            `json:"user_id"`
	JobID            string            `json:"job_id"`
	ExecutionLeaseID string            `json:"execution_lease_id,omitempty"`
	Kind             string            `json:"kind"`
	State            string            `json:"state"`
	Title            string            `json:"title"`
	Detail           string            `json:"detail"`
	ActionSHA256     string            `json:"action_sha256"`
	CreatedAt        string            `json:"created_at"`
	ExpiresAt        string            `json:"expires_at"`
	Reply            *interactionReply `json:"reply,omitempty"`
	RepliedAt        string            `json:"replied_at,omitempty"`
}

type contentEnvelope struct {
	ContentLease contentLease `json:"content_lease"`
}

type contentLease struct {
	ID     string `json:"id"`
	JobID  string `json:"job_id"`
	Kind   string `json:"kind"`
	State  string `json:"state"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type enrollmentDevice struct {
	ID       string `json:"id"`
	UserID   string `json:"user_id"`
	Role     string `json:"role"`
	Platform string `json:"platform"`
	Status   string `json:"status"`
}

type memberIdentity struct {
	User struct {
		ID     string `json:"id"`
		Role   string `json:"role"`
		Status string `json:"status"`
	} `json:"user"`
	Device struct {
		ID       string `json:"id"`
		Role     string `json:"role"`
		Platform string `json:"platform"`
		Status   string `json:"status"`
	} `json:"device"`
	CodexBinding struct {
		ID     string `json:"id"`
		Status string `json:"status"`
	} `json:"codex_binding"`
}

func (c *memberClient) request(method, route string, body []byte) (*http.Response, error) {
	endpoint, err := parseMemberEndpoint(c.config.Endpoint, c.allowHTTP)
	if err != nil {
		return nil, err
	}
	basePath := endpoint.Path
	requestURL := *endpoint
	requestURL.Path = basePath + route
	requestPath := requestURL.EscapedPath()
	if requestURL.RawQuery != "" {
		requestPath += "?" + requestURL.RawQuery
	}
	bodyDigest := sha256.Sum256(body)
	timestamp := strconv.FormatInt(c.now().Unix(), 10)
	nonce, err := c.nonce()
	if err != nil || !regexp.MustCompile(`^[a-f0-9]{32}$`).MatchString(nonce) {
		return nil, errors.New("cannot create request nonce")
	}
	canonical := strings.Join([]string{
		authScheme, method, requestPath, c.config.UserID, c.config.DeviceID,
		timestamp, nonce, hex.EncodeToString(bodyDigest[:]),
	}, "\n")
	signature, err := c.signer.Sign([]byte(canonical))
	if err != nil {
		return nil, err
	}
	request, err := http.NewRequest(method, requestURL.String(), bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-Wu-User", c.config.UserID)
	request.Header.Set("X-Wu-Device", c.config.DeviceID)
	request.Header.Set("X-Wu-Time", timestamp)
	request.Header.Set("X-Wu-Nonce", nonce)
	request.Header.Set("X-Wu-Body-SHA256", hex.EncodeToString(bodyDigest[:]))
	request.Header.Set("X-Wu-Signature", signature)
	return c.http.Do(request)
}

func parseMemberEndpoint(raw string, allowHTTP bool) (*url.URL, error) {
	endpoint, err := url.Parse(raw)
	if err != nil || endpoint.Host == "" || endpoint.RawQuery != "" || endpoint.Fragment != "" || endpoint.User != nil {
		return nil, errors.New("invalid member endpoint")
	}
	if endpoint.Scheme != "https" && !(allowHTTP && endpoint.Scheme == "http") {
		return nil, errors.New("member endpoint must use HTTPS")
	}
	endpoint.Path = strings.TrimRight(endpoint.Path, "/")
	if !strings.HasSuffix(endpoint.Path, "/two-head-wu/v2") {
		return nil, errors.New("member endpoint must end with /two-head-wu/v2")
	}
	return endpoint, nil
}

func decodeJSON(response *http.Response, target any) error {
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 1024*1024+1))
	if err != nil {
		return err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("member relay returned HTTP %d", response.StatusCode)
	}
	if len(data) > 1024*1024 || json.Unmarshal(data, target) != nil {
		return errors.New("member relay returned invalid JSON")
	}
	return nil
}

func platformIdentity() (string, string, error) {
	if runtime.GOOS == "darwin" {
		return "macos", "secure-enclave", nil
	}
	if runtime.GOOS == "windows" {
		return "windows", "tpm-cng", nil
	}
	return "", "", errors.New("member Air supports only macOS and Windows")
}

func enrollMember(
	endpointText, token, reviewRoot string,
	platform, expectedProvider string,
	key hardwareKey,
	httpClient *http.Client,
	now func() time.Time,
	nonceGenerator func() (string, error),
	allowHTTP bool,
) (config, error) {
	endpoint, err := parseMemberEndpoint(endpointText, allowHTTP)
	if err != nil {
		return config{}, err
	}
	if !pairPattern.MatchString(token) {
		return config{}, errors.New("member pairing token is invalid")
	}
	if reviewRoot != "" && !filepath.IsAbs(reviewRoot) {
		return config{}, errors.New("review_root must be absolute")
	}
	material, err := key.Create()
	if err != nil {
		return config{}, err
	}
	providers := map[string]string{"macos": "secure-enclave", "windows": "tpm-cng"}
	if providers[platform] != expectedProvider || material.Provider != expectedProvider || validateKeyMaterial(material, expectedProvider) != nil {
		return config{}, errors.New("hardware key does not satisfy member pairing policy")
	}
	tokenDigest := sha256.Sum256([]byte(token))
	timestamp := strconv.FormatInt(now().Unix(), 10)
	nonce, err := nonceGenerator()
	if err != nil || !regexp.MustCompile(`^[a-f0-9]{32}$`).MatchString(nonce) {
		return config{}, errors.New("cannot create enrollment nonce")
	}
	canonical := strings.Join([]string{
		"TWO-HEAD-WU-MEMBER-ENROLL-V2",
		hex.EncodeToString(tokenDigest[:]),
		platform,
		material.Provider,
		material.PublicKeySPKIBase64,
		timestamp,
		nonce,
	}, "\n")
	signature, err := key.Sign([]byte(canonical))
	if err != nil {
		return config{}, err
	}
	payload, _ := json.Marshal(map[string]string{
		"platform": platform, "key_provider": material.Provider,
		"public_key_spki_base64": material.PublicKeySPKIBase64,
		"timestamp":              timestamp, "nonce": nonce, "signature_base64": signature,
	})
	enrollmentURL := *endpoint
	enrollmentURL.Path += "/enroll"
	request, err := http.NewRequest(http.MethodPost, enrollmentURL.String(), bytes.NewReader(payload))
	if err != nil {
		return config{}, errors.New("cannot create member pairing request")
	}
	request.Header.Set("Authorization", "MemberEnrollment "+token)
	request.Header.Set("Content-Type", "application/json")
	response, err := httpClient.Do(request)
	if err != nil {
		return config{}, errors.New("member pairing request failed")
	}
	var envelope struct {
		Device enrollmentDevice `json:"device"`
	}
	if err := decodeJSON(response, &envelope); err != nil {
		return config{}, err
	}
	device := envelope.Device
	if !userPattern.MatchString(device.UserID) || !devicePattern.MatchString(device.ID) ||
		device.Role != "air" || device.Platform != platform || device.Status != "active" {
		return config{}, errors.New("member relay returned invalid enrollment")
	}
	cleanReviewRoot := ""
	if reviewRoot != "" {
		cleanReviewRoot = filepath.Clean(reviewRoot)
	}
	return config{
		SchemaVersion: 2,
		Endpoint:      endpoint.String(),
		UserID:        device.UserID,
		DeviceID:      device.ID,
		ReviewRoot:    cleanReviewRoot,
	}, nil
}

func boundedUTF8(value string, maximum int) bool {
	return utf8.ValidString(value) && value != "" && utf8.RuneCountInString(value) <= maximum
}

func validateMemberInteraction(value memberInteraction, expectedUserID, expectedJobID string) error {
	if value.SchemaVersion != 2 || !interactionPattern.MatchString(value.ID) || value.ExecutionLeaseID != "" ||
		value.UserID != expectedUserID || value.JobID != expectedJobID || !jobPattern.MatchString(value.JobID) {
		return errors.New("member relay returned an invalid interaction identity")
	}
	if value.Kind != "command-approval" && value.Kind != "user-input" {
		return errors.New("member relay returned an invalid interaction kind")
	}
	states := map[string]bool{"pending": true, "answered": true, "denied": true, "cancelled": true, "expired": true}
	if !states[value.State] || !boundedUTF8(value.Title, 200) || !boundedUTF8(value.Detail, 4000) ||
		!hexPattern.MatchString(value.ActionSHA256) {
		return errors.New("member relay returned invalid interaction content")
	}
	createdAt, createdError := time.Parse(time.RFC3339, value.CreatedAt)
	expiresAt, expiresError := time.Parse(time.RFC3339, value.ExpiresAt)
	if createdError != nil || expiresError != nil || !expiresAt.After(createdAt) {
		return errors.New("member relay returned invalid interaction timing")
	}
	if value.State == "pending" {
		if value.Reply != nil || value.RepliedAt != "" {
			return errors.New("pending member interaction carried a reply")
		}
		return nil
	}
	if value.Reply == nil || value.RepliedAt == "" {
		return errors.New("terminal member interaction omitted its reply")
	}
	if _, err := time.Parse(time.RFC3339, value.RepliedAt); err != nil {
		return errors.New("member relay returned invalid interaction reply timing")
	}
	expected := map[string]map[string]bool{
		"answered":  {"accept": true, "answer": true},
		"denied":    {"decline": true},
		"cancelled": {"cancel": true},
		"expired":   {"cancel": true},
	}
	if !expected[value.State][value.Reply.Decision] {
		return errors.New("member interaction reply does not match its state")
	}
	if value.Reply.Decision == "answer" {
		if value.Kind != "user-input" || !boundedUTF8(value.Reply.Answer, 4000) {
			return errors.New("member interaction returned an invalid answer")
		}
	} else if value.Reply.Answer != "" || (value.Reply.Decision == "accept" && value.Kind != "command-approval") {
		return errors.New("member interaction returned an invalid decision")
	}
	return nil
}

func (c *memberClient) listInteractions(jobID string) ([]memberInteraction, error) {
	if !jobPattern.MatchString(jobID) {
		return nil, errors.New("invalid member job id")
	}
	response, err := c.request(http.MethodGet, "/jobs/"+jobID+"/interactions", nil)
	if err != nil {
		return nil, err
	}
	var envelope struct {
		Interactions []memberInteraction `json:"interactions"`
	}
	if err := decodeJSON(response, &envelope); err != nil {
		return nil, err
	}
	if len(envelope.Interactions) > 256 {
		return nil, errors.New("member relay returned too many interactions")
	}
	seen := map[string]bool{}
	for _, interaction := range envelope.Interactions {
		if seen[interaction.ID] {
			return nil, errors.New("member relay returned a duplicate interaction")
		}
		if err := validateMemberInteraction(interaction, c.config.UserID, jobID); err != nil {
			return nil, err
		}
		seen[interaction.ID] = true
	}
	return envelope.Interactions, nil
}

func (c *memberClient) diagnose() (memberIdentity, error) {
	response, err := c.request(http.MethodGet, "/me", nil)
	if err != nil {
		return memberIdentity{}, err
	}
	var value memberIdentity
	if err := decodeJSON(response, &value); err != nil {
		return memberIdentity{}, err
	}
	platform, _, err := platformIdentity()
	if err != nil {
		return memberIdentity{}, err
	}
	if value.User.ID != c.config.UserID || (value.User.Role != "owner" && value.User.Role != "member") || value.User.Status != "active" ||
		value.Device.ID != c.config.DeviceID || value.Device.Role != "air" ||
		value.Device.Platform != platform || value.Device.Status != "active" ||
		!codexBindingPattern.MatchString(value.CodexBinding.ID) || value.CodexBinding.Status != "active" {
		return memberIdentity{}, errors.New("member identity diagnosis failed")
	}
	return value, nil
}

func (c *memberClient) replyInteraction(jobID, interactionID, decision, answer string) (memberInteraction, error) {
	if !jobPattern.MatchString(jobID) || !interactionPattern.MatchString(interactionID) {
		return memberInteraction{}, errors.New("invalid member interaction target")
	}
	if decision != "accept" && decision != "decline" && decision != "cancel" && decision != "answer" {
		return memberInteraction{}, errors.New("invalid member interaction decision")
	}
	payload := map[string]string{"decision": decision}
	if decision == "answer" {
		if !boundedUTF8(answer, 4000) {
			return memberInteraction{}, errors.New("member answer must contain 1 to 4000 UTF-8 characters")
		}
		if err := rejectMemberSecretBytes([]byte(answer)); err != nil {
			return memberInteraction{}, err
		}
		payload["answer"] = answer
	} else if answer != "" {
		return memberInteraction{}, errors.New("only an answer decision can carry text")
	}
	body, _ := json.Marshal(payload)
	response, err := c.request(
		http.MethodPost, "/jobs/"+jobID+"/interactions/"+interactionID+"/reply", body,
	)
	if err != nil {
		return memberInteraction{}, err
	}
	var envelope struct {
		Interaction memberInteraction `json:"interaction"`
	}
	if err := decodeJSON(response, &envelope); err != nil {
		return memberInteraction{}, err
	}
	if envelope.Interaction.ID != interactionID {
		return memberInteraction{}, errors.New("member relay replied for the wrong interaction")
	}
	if err := validateMemberInteraction(envelope.Interaction, c.config.UserID, jobID); err != nil {
		return memberInteraction{}, err
	}
	if envelope.Interaction.State == "pending" || envelope.Interaction.Reply == nil ||
		envelope.Interaction.Reply.Decision != decision {
		return memberInteraction{}, errors.New("member relay did not confirm the interaction reply")
	}
	return envelope.Interaction, nil
}

func (c *memberClient) fetchResult(jobID string) (string, error) {
	if !jobPattern.MatchString(jobID) {
		return "", errors.New("invalid member job id")
	}
	response, err := c.request(http.MethodGet, "/jobs/"+jobID, nil)
	if err != nil {
		return "", err
	}
	var jobEnvelope struct {
		Job memberJob `json:"job"`
	}
	if err := decodeJSON(response, &jobEnvelope); err != nil {
		return "", err
	}
	if jobEnvelope.Job.ID != jobID || jobEnvelope.Job.State != "succeeded" {
		return "", errors.New("member result is not ready")
	}
	var selected contentLease
	for _, leaseID := range jobEnvelope.Job.ContentLeaseIDs {
		if !contentPattern.MatchString(leaseID) {
			return "", errors.New("member job returned invalid content lease")
		}
		response, err := c.request(http.MethodGet, "/content/"+leaseID, nil)
		if err != nil {
			return "", err
		}
		var envelope struct {
			ContentLease contentLease `json:"content_lease"`
		}
		if err := decodeJSON(response, &envelope); err != nil {
			return "", err
		}
		lease := envelope.ContentLease
		if lease.ID == leaseID && lease.JobID == jobID && lease.Kind == "result-package" && lease.State == "available" {
			selected = lease
		}
	}
	if selected.ID == "" || !hexPattern.MatchString(selected.SHA256) || selected.Size <= 0 || selected.Size > 50*1024*1024 {
		return "", errors.New("member result lease is unavailable")
	}
	response, err = c.request(http.MethodGet, "/jobs/"+jobID+"/result", nil)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("member relay returned HTTP %d", response.StatusCode)
	}
	result, err := io.ReadAll(io.LimitReader(response.Body, 50*1024*1024+1))
	if err != nil || int64(len(result)) != selected.Size {
		return "", errors.New("member result size verification failed")
	}
	digest := sha256.Sum256(result)
	digestText := hex.EncodeToString(digest[:])
	if digestText != selected.SHA256 {
		return "", errors.New("member result hash verification failed")
	}
	reviewRoot, err := c.reviewRoot()
	if err != nil {
		return "", err
	}
	jobDirectory := filepath.Join(reviewRoot, jobID)
	if err := os.MkdirAll(jobDirectory, 0700); err != nil {
		return "", errors.New("cannot create member review directory")
	}
	finalPath := filepath.Join(jobDirectory, "result-"+digestText[:12]+".tar.gz")
	if err := persistReviewFile(finalPath, result, digestText); err != nil {
		return "", err
	}
	receiptBody, _ := json.Marshal(map[string]string{"sha256": digestText})
	response, err = c.request(http.MethodPost, "/content/"+selected.ID+"/receipt", receiptBody)
	if err != nil {
		return finalPath, fmt.Errorf("result saved but receipt failed: %w", err)
	}
	var receipt struct {
		ContentLease contentLease `json:"content_lease"`
	}
	if err := decodeJSON(response, &receipt); err != nil {
		return finalPath, fmt.Errorf("result saved but receipt failed: %w", err)
	}
	if receipt.ContentLease.ID != selected.ID || receipt.ContentLease.SHA256 != digestText || receipt.ContentLease.State != "purged" {
		return finalPath, errors.New("result saved but receipt was not confirmed")
	}
	return finalPath, nil
}

func excludedProjectName(name string) bool {
	lower := strings.ToLower(name)
	excluded := map[string]bool{
		".git": true, ".env": true, "auth.json": true,
		"node_modules": true, "__pycache__": true, ".venv": true, "vendor": true, "target": true,
		".ssh": true, ".aws": true, ".azure": true, ".gnupg": true, ".kube": true, "gcloud": true,
		".npmrc": true, ".pypirc": true, ".netrc": true, "_netrc": true, ".git-credentials": true,
	}
	if excluded[lower] || strings.HasPrefix(lower, ".env.") ||
		strings.HasPrefix(lower, "id_rsa") || strings.HasPrefix(lower, "id_ed25519") ||
		strings.HasPrefix(lower, "id_ecdsa") {
		return true
	}
	for _, suffix := range []string{".key", ".pem", ".p12", ".pfx"} {
		if strings.HasSuffix(lower, suffix) {
			return true
		}
	}
	return credentialNamePattern.MatchString(lower) || (strings.HasPrefix(lower, "auth") && strings.HasSuffix(lower, ".json"))
}

func rejectMemberSecretBytes(data []byte) error {
	for _, pattern := range memberSecretPatterns {
		if pattern.Match(data) {
			return errors.New("member content DLP rejected secret-shaped bytes")
		}
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" && bytes.Contains(data, []byte(filepath.Clean(home))) {
		return errors.New("member content DLP rejected a private local path")
	}
	return nil
}

func buildProjectCapsule(source string) ([]byte, string, error) {
	root, err := filepath.Abs(source)
	if err != nil {
		return nil, "", errors.New("cannot resolve member project directory")
	}
	root = filepath.Clean(root)
	rootInfo, err := os.Lstat(root)
	if err != nil || !rootInfo.IsDir() || rootInfo.Mode()&os.ModeSymlink != 0 {
		return nil, "", errors.New("member project must be a real directory, not a symlink")
	}
	var output bytes.Buffer
	gzipWriter := gzip.NewWriter(&output)
	gzipWriter.Header.ModTime = time.Unix(0, 0)
	tarWriter := tar.NewWriter(gzipWriter)
	total := int64(0)
	entries := 0
	walkError := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return errors.New("cannot inspect member project")
		}
		if path == root {
			return nil
		}
		if excludedProjectName(entry.Name()) {
			if entry.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return errors.New("cannot inspect member project entry")
		}
		if !info.IsDir() && !info.Mode().IsRegular() {
			return nil
		}
		relative, err := filepath.Rel(root, path)
		if err != nil || relative == "." || filepath.IsAbs(relative) || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return errors.New("member project entry escaped the selected directory")
		}
		entries++
		if entries > maximumCapsuleEntries {
			return errors.New("member project has too many capsule entries")
		}
		header, err := tar.FileInfoHeader(info, "")
		if err != nil {
			return errors.New("cannot encode member project entry")
		}
		header.Name = filepath.ToSlash(relative)
		header.Uid, header.Gid, header.Uname, header.Gname = 0, 0, "", ""
		header.ModTime, header.AccessTime, header.ChangeTime = time.Unix(0, 0), time.Time{}, time.Time{}
		header.Mode &= 0755
		if info.IsDir() {
			header.Name += "/"
			return tarWriter.WriteHeader(header)
		}
		file, err := os.Open(path)
		if err != nil {
			return errors.New("cannot open member project file")
		}
		openedInfo, err := file.Stat()
		if err != nil || !openedInfo.Mode().IsRegular() || !os.SameFile(info, openedInfo) {
			file.Close()
			return errors.New("member project changed while creating its capsule")
		}
		total += openedInfo.Size()
		if total > maximumCapsuleBytes {
			file.Close()
			return errors.New("member project capsule exceeds the 50 MiB limit")
		}
		header.Size = openedInfo.Size()
		if err := tarWriter.WriteHeader(header); err != nil {
			file.Close()
			return errors.New("cannot encode member project file")
		}
		data, err := io.ReadAll(io.LimitReader(file, openedInfo.Size()+1))
		if err != nil || int64(len(data)) != openedInfo.Size() {
			file.Close()
			return errors.New("member project changed while creating its capsule")
		}
		if err := rejectMemberSecretBytes(data); err != nil {
			file.Close()
			return err
		}
		if written, err := tarWriter.Write(data); err != nil || written != len(data) {
			file.Close()
			return errors.New("cannot encode member project file")
		}
		if err := file.Close(); err != nil {
			return errors.New("cannot close member project file")
		}
		return nil
	})
	if walkError != nil {
		tarWriter.Close()
		gzipWriter.Close()
		return nil, "", walkError
	}
	if err := tarWriter.Close(); err != nil || gzipWriter.Close() != nil {
		return nil, "", errors.New("cannot finalize member project capsule")
	}
	if entries == 0 || output.Len() == 0 || output.Len() > maximumCapsuleBytes {
		return nil, "", errors.New("member project capsule is empty or exceeds the 50 MiB limit")
	}
	data := output.Bytes()
	digest := sha256.Sum256(data)
	return data, hex.EncodeToString(digest[:]), nil
}

func requestIDFromRandom() (string, error) {
	data := make([]byte, 12)
	if _, err := rand.Read(data); err != nil {
		return "", errors.New("cannot create member request id")
	}
	return "call-" + hex.EncodeToString(data), nil
}

func capsuleRequestID(jobRequestID string) string {
	digest := sha256.Sum256([]byte("project-capsule\x00" + jobRequestID))
	return "call-" + hex.EncodeToString(digest[:12])
}

func artifactRequestID(jobRequestID string, index int) string {
	digest := sha256.Sum256([]byte(fmt.Sprintf("input-artifact\x00%s\x00%d", jobRequestID, index)))
	return "call-" + hex.EncodeToString(digest[:12])
}

type inputArtifact struct {
	Filename  string
	MediaType string
	Data      []byte
	SHA256    string
}

func readInputArtifact(path string) (inputArtifact, error) {
	clean, err := filepath.Abs(path)
	if err != nil {
		return inputArtifact{}, errors.New("cannot resolve member input artifact")
	}
	info, err := os.Lstat(clean)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return inputArtifact{}, errors.New("member input artifact must be a real regular file")
	}
	filename := filepath.Base(clean)
	if excludedProjectName(filename) {
		return inputArtifact{}, errors.New("credential-shaped member input artifact is forbidden")
	}
	file, err := os.Open(clean)
	if err != nil {
		return inputArtifact{}, errors.New("cannot open member input artifact")
	}
	openedInfo, err := file.Stat()
	if err != nil || !openedInfo.Mode().IsRegular() || !os.SameFile(info, openedInfo) {
		file.Close()
		return inputArtifact{}, errors.New("member input artifact changed while reading")
	}
	data, err := io.ReadAll(io.LimitReader(file, maximumCapsuleBytes+1))
	closeErr := file.Close()
	if err != nil || closeErr != nil || len(data) == 0 || len(data) > maximumCapsuleBytes || int64(len(data)) != openedInfo.Size() {
		return inputArtifact{}, errors.New("member input artifact is empty, changed, or exceeds 50 MiB")
	}
	if err := rejectMemberSecretBytes(data); err != nil {
		return inputArtifact{}, err
	}
	digest := sha256.Sum256(data)
	mediaType := mime.TypeByExtension(strings.ToLower(filepath.Ext(filename)))
	if mediaType == "" {
		mediaType = "application/octet-stream"
	}
	if separator := strings.IndexByte(mediaType, ';'); separator >= 0 {
		mediaType = mediaType[:separator]
	}
	return inputArtifact{
		Filename: filename, MediaType: mediaType, Data: data, SHA256: hex.EncodeToString(digest[:]),
	}, nil
}

func (c *memberClient) submitProject(project, instruction, requestID string, artifactPaths []string) (memberJob, error) {
	if !utf8.ValidString(instruction) || len(instruction) == 0 || len(instruction) > 20_000 || strings.TrimSpace(instruction) == "" {
		return memberJob{}, errors.New("member instruction must contain 1 to 20000 UTF-8 bytes")
	}
	if !regexp.MustCompile(`^call-[a-f0-9]{24}$`).MatchString(requestID) {
		return memberJob{}, errors.New("invalid member request id")
	}
	if len(artifactPaths) > 31 {
		return memberJob{}, errors.New("member job accepts at most 31 explicit input artifacts")
	}
	capsule, digest, err := buildProjectCapsule(project)
	if err != nil {
		return memberJob{}, err
	}
	artifacts := make([]inputArtifact, 0, len(artifactPaths))
	aggregate := int64(len(capsule))
	for _, path := range artifactPaths {
		artifact, err := readInputArtifact(path)
		if err != nil {
			return memberJob{}, err
		}
		aggregate += int64(len(artifact.Data))
		if aggregate > maximumCapsuleBytes {
			return memberJob{}, errors.New("member project capsule and input artifacts exceed 50 MiB")
		}
		artifacts = append(artifacts, artifact)
	}
	draftBody, _ := json.Marshal(map[string]any{
		"request_id": requestID, "instruction": instruction,
		"capabilities": []string{"codex:project-task"},
	})
	response, err := c.request(http.MethodPost, "/jobs/draft", draftBody)
	if err != nil {
		return memberJob{}, err
	}
	var draft struct {
		Job memberJob `json:"job"`
	}
	if err := decodeJSON(response, &draft); err != nil {
		return memberJob{}, err
	}
	if !jobPattern.MatchString(draft.Job.ID) {
		return memberJob{}, errors.New("member relay returned invalid job draft")
	}
	if draft.Job.State != "staging" {
		if draft.Job.State == "queued" || draft.Job.State == "leased" || draft.Job.State == "running" || draft.Job.State == "waiting_user" || draft.Job.State == "uploading" || draft.Job.State == "succeeded" {
			return draft.Job, nil
		}
		return draft.Job, errors.New("member job draft is not submit-ready")
	}
	uploadBody, _ := json.Marshal(map[string]any{
		"request_id": capsuleRequestID(requestID), "kind": "project-capsule",
		"filename": "project.tar.gz", "media_type": "application/gzip",
		"sha256": digest, "content_base64": base64.StdEncoding.EncodeToString(capsule),
	})
	response, err = c.request(http.MethodPost, "/jobs/"+draft.Job.ID+"/content", uploadBody)
	if err != nil {
		return draft.Job, err
	}
	var uploaded contentEnvelope
	if err := decodeJSON(response, &uploaded); err != nil {
		return draft.Job, err
	}
	if !contentPattern.MatchString(uploaded.ContentLease.ID) || uploaded.ContentLease.JobID != draft.Job.ID ||
		uploaded.ContentLease.Kind != "project-capsule" ||
		uploaded.ContentLease.State != "available" || uploaded.ContentLease.SHA256 != digest ||
		uploaded.ContentLease.Size != int64(len(capsule)) {
		return draft.Job, errors.New("member relay did not confirm the project capsule")
	}
	for index, artifact := range artifacts {
		artifactBody, _ := json.Marshal(map[string]any{
			"request_id": artifactRequestID(requestID, index), "kind": "input-artifact",
			"filename": artifact.Filename, "media_type": artifact.MediaType,
			"sha256": artifact.SHA256, "content_base64": base64.StdEncoding.EncodeToString(artifact.Data),
		})
		response, err = c.request(http.MethodPost, "/jobs/"+draft.Job.ID+"/content", artifactBody)
		if err != nil {
			return draft.Job, err
		}
		var confirmed contentEnvelope
		if err := decodeJSON(response, &confirmed); err != nil {
			return draft.Job, err
		}
		lease := confirmed.ContentLease
		if !contentPattern.MatchString(lease.ID) || lease.JobID != draft.Job.ID || lease.Kind != "input-artifact" ||
			lease.State != "available" || lease.SHA256 != artifact.SHA256 || lease.Size != int64(len(artifact.Data)) {
			return draft.Job, errors.New("member relay did not confirm an input artifact")
		}
	}
	response, err = c.request(http.MethodPost, "/jobs/"+draft.Job.ID+"/submit", []byte("{}"))
	if err != nil {
		return draft.Job, err
	}
	var submitted struct {
		Job memberJob `json:"job"`
	}
	if err := decodeJSON(response, &submitted); err != nil {
		return draft.Job, err
	}
	if submitted.Job.ID != draft.Job.ID || submitted.Job.State != "queued" {
		return draft.Job, errors.New("member relay did not queue the project job")
	}
	return submitted.Job, nil
}

func persistReviewFile(path string, data []byte, expectedDigest string) error {
	existing, err := os.ReadFile(path)
	if err == nil {
		digest := sha256.Sum256(existing)
		if hex.EncodeToString(digest[:]) != expectedDigest || !bytes.Equal(existing, data) {
			return errors.New("existing review result does not match the relay")
		}
		return nil
	}
	if !os.IsNotExist(err) {
		return errors.New("cannot inspect existing member result")
	}
	return atomicFile(path, data)
}

func (c *memberClient) reviewRoot() (string, error) {
	if c.config.ReviewRoot != "" {
		if !filepath.IsAbs(c.config.ReviewRoot) {
			return "", errors.New("review_root must be absolute")
		}
		return filepath.Clean(c.config.ReviewRoot), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", errors.New("cannot resolve member home directory")
	}
	return filepath.Join(home, "Documents", "TwoHeadWu Reviews"), nil
}

func atomicFile(path string, data []byte) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".result-*.tmp")
	if err != nil {
		return errors.New("cannot stage member result")
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0600); err != nil {
		temporary.Close()
		return errors.New("cannot protect member result")
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return errors.New("cannot write member result")
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return errors.New("cannot sync member result")
	}
	if err := temporary.Close(); err != nil || os.Rename(temporaryPath, path) != nil {
		return errors.New("cannot finalize member result")
	}
	return nil
}

func randomNonce() (string, error) {
	data := make([]byte, 16)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return hex.EncodeToString(data), nil
}

func loadConfig(path string) (config, error) {
	info, statErr := os.Lstat(path)
	if statErr != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 ||
		(runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0) {
		return config{}, errors.New("Air configuration is unavailable or not private")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return config{}, errors.New("Air configuration is unavailable")
	}
	var value config
	if json.Unmarshal(data, &value) != nil || value.SchemaVersion != 2 || !userPattern.MatchString(value.UserID) || !devicePattern.MatchString(value.DeviceID) {
		return config{}, errors.New("Air configuration is invalid")
	}
	return value, nil
}

func saveConfig(path string, value config) error {
	if _, err := os.Lstat(path); err == nil || !os.IsNotExist(err) {
		return errors.New("Air configuration already exists; Mini-side revocation is required before re-pairing")
	}
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0700); err != nil || os.Chmod(directory, 0700) != nil {
		return errors.New("cannot protect Air configuration directory")
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return errors.New("cannot encode Air configuration")
	}
	data = append(data, '\n')
	if err := atomicFile(path, data); err != nil {
		return errors.New("cannot persist Air configuration")
	}
	return nil
}

func productionHTTPClient() *http.Client {
	return &http.Client{
		Timeout: 60 * time.Second,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func parseEnrollmentArguments(arguments []string) (string, string, string, error) {
	values := map[string]string{}
	for len(arguments) > 0 {
		if len(arguments) < 2 || (arguments[0] != "--endpoint" && arguments[0] != "--token-env" && arguments[0] != "--review-root") {
			return "", "", "", errors.New("usage: two-head-wu-air enroll --endpoint URL --token-env NAME [--review-root ABSOLUTE_PATH]")
		}
		if _, exists := values[arguments[0]]; exists || arguments[1] == "" {
			return "", "", "", errors.New("duplicate or empty Air enrollment option")
		}
		values[arguments[0]] = arguments[1]
		arguments = arguments[2:]
	}
	if values["--endpoint"] == "" || !envNamePattern.MatchString(values["--token-env"]) {
		return "", "", "", errors.New("Air enrollment requires endpoint and a valid token environment name")
	}
	return values["--endpoint"], values["--token-env"], values["--review-root"], nil
}

func parseSubmitArguments(arguments []string) (string, string, []string, string, error) {
	values := map[string]string{}
	separator := -1
	for index, value := range arguments {
		if value == "--" {
			separator = index
			break
		}
	}
	if separator < 0 || separator == len(arguments)-1 {
		return "", "", nil, "", errors.New("usage: two-head-wu-air submit --project PATH [--artifact FILE ...] [--request-id CALL_ID] -- INSTRUCTION")
	}
	options := arguments[:separator]
	artifacts := []string{}
	for len(options) > 0 {
		if len(options) < 2 || (options[0] != "--project" && options[0] != "--artifact" && options[0] != "--request-id") {
			return "", "", nil, "", errors.New("usage: two-head-wu-air submit --project PATH [--artifact FILE ...] [--request-id CALL_ID] -- INSTRUCTION")
		}
		if options[1] == "" {
			return "", "", nil, "", errors.New("empty Air submit option")
		}
		if options[0] == "--artifact" {
			artifacts = append(artifacts, options[1])
			options = options[2:]
			continue
		}
		if _, exists := values[options[0]]; exists {
			return "", "", nil, "", errors.New("duplicate Air submit option")
		}
		values[options[0]] = options[1]
		options = options[2:]
	}
	if values["--project"] == "" {
		return "", "", nil, "", errors.New("Air submit requires an explicit project directory")
	}
	requestID := values["--request-id"]
	if requestID == "" {
		var err error
		requestID, err = requestIDFromRandom()
		if err != nil {
			return "", "", nil, "", err
		}
	}
	return values["--project"], requestID, artifacts, strings.Join(arguments[separator+1:], " "), nil
}

func defaultConfigPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	if runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "Application Support", "TwoHeadWu", "air.json"), nil
	}
	if runtime.GOOS == "windows" {
		root := os.Getenv("LOCALAPPDATA")
		if root == "" {
			return "", errors.New("LOCALAPPDATA is unavailable")
		}
		return filepath.Join(root, "TwoHeadWu", "air.json"), nil
	}
	return "", errors.New("Air supports only macOS and Windows")
}

func legacyConfigPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	if runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "Application Support", "TwoHeadWu", "member.json"), nil
	}
	if runtime.GOOS == "windows" {
		root := os.Getenv("LOCALAPPDATA")
		if root == "" {
			return "", errors.New("LOCALAPPDATA is unavailable")
		}
		return filepath.Join(root, "TwoHeadWu", "member.json"), nil
	}
	return "", errors.New("Air supports only macOS and Windows")
}

func migrateLegacyConfig(currentPath, oldPath string) error {
	if _, err := os.Lstat(currentPath); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return errors.New("cannot inspect Air configuration")
	}
	if _, err := os.Lstat(oldPath); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return errors.New("cannot inspect legacy Air configuration")
	}
	value, err := loadConfig(oldPath)
	if err != nil {
		return errors.New("legacy Air configuration is invalid")
	}
	if err := saveConfig(currentPath, value); err != nil {
		return errors.New("cannot migrate legacy Air configuration")
	}
	verified, err := loadConfig(currentPath)
	if err != nil || verified != value {
		return errors.New("migrated Air configuration failed verification")
	}
	if err := os.Remove(oldPath); err != nil {
		return errors.New("legacy Air configuration could not be retired")
	}
	return nil
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, airUsage)
		os.Exit(2)
	}
	configPath, err := defaultConfigPath()
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(2)
	}
	oldConfigPath, err := legacyConfigPath()
	if err != nil || migrateLegacyConfig(configPath, oldConfigPath) != nil {
		fmt.Fprintln(os.Stderr, "Error: cannot migrate the legacy Air configuration")
		os.Exit(2)
	}
	executable, _ := os.Executable()
	key := nativeSigner{programDir: filepath.Dir(executable)}
	httpClient := productionHTTPClient()
	if os.Args[1] == "enroll" {
		endpoint, tokenEnvironment, reviewRoot, err := parseEnrollmentArguments(os.Args[2:])
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		if _, err := os.Lstat(configPath); err == nil || !os.IsNotExist(err) {
			fmt.Fprintln(os.Stderr, "Error: Air configuration already exists; Mini-side revocation is required before re-pairing")
			os.Exit(2)
		}
		token, present := os.LookupEnv(tokenEnvironment)
		_ = os.Unsetenv(tokenEnvironment)
		if !present {
			fmt.Fprintln(os.Stderr, "Error: Air pairing token environment is unavailable")
			os.Exit(2)
		}
		platform, provider, err := platformIdentity()
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		value, err := enrollMember(endpoint, token, reviewRoot, platform, provider, key, httpClient, time.Now, randomNonce, false)
		token = ""
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		if err := saveConfig(configPath, value); err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		encoded, _ := json.Marshal(map[string]string{"user_id": value.UserID, "device_id": value.DeviceID})
		fmt.Println(string(encoded))
		return
	}
	if os.Args[1] == "submit" {
		project, requestID, artifacts, instruction, err := parseSubmitArguments(os.Args[2:])
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		value, err := loadConfig(configPath)
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		client := memberClient{
			config: value, signer: key,
			http: httpClient, now: time.Now, nonce: randomNonce,
		}
		job, err := client.submitProject(project, instruction, requestID, artifacts)
		if err != nil {
			if job.ID != "" {
				fmt.Fprintf(os.Stderr, "Error: %v (recoverable draft: %s, request: %s)\n", err, job.ID, requestID)
			} else {
				fmt.Fprintln(os.Stderr, "Error:", err)
			}
			os.Exit(2)
		}
		encoded, _ := json.Marshal(map[string]string{"job_id": job.ID, "state": job.State, "request_id": requestID})
		fmt.Println(string(encoded))
		return
	}
	if os.Args[1] == "invoke" {
		capabilityID, inputText, requestID, err := parseInvokeArguments(os.Args[2:])
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		input, err := decodeCapabilityInput(inputText)
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		value, err := loadConfig(configPath)
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		client := memberClient{config: value, signer: key, http: httpClient, now: time.Now, nonce: randomNonce}
		confirmation, err := client.capabilityConfirmation(capabilityID)
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		var privateKey *ecdsa.PrivateKey
		if confirmation == "owner-password" {
			password, err := readPassword("两头乌高风险操作确认码（输入四个空格）: ")
			if err != nil {
				fmt.Fprintln(os.Stderr, "Error:", err)
				os.Exit(2)
			}
			stored, err := loadEncryptedApprovalKey(approvalKeyPath(configPath))
			if err == nil {
				privateKey, err = decryptApprovalPrivateKey(stored, password)
			}
			wipe(password)
			if err != nil {
				fmt.Fprintln(os.Stderr, "Error:", err)
				os.Exit(2)
			}
		}
		job, err := client.invokeCapability(capabilityID, requestID, confirmation, input, privateKey)
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		encoded, _ := json.Marshal(map[string]string{"job_id": job.ID, "state": job.State, "request_id": requestID})
		fmt.Println(string(encoded))
		return
	}
	if os.Args[1] == "approval-init" || os.Args[1] == "approval-register" || os.Args[1] == "approval-status" {
		if len(os.Args) != 2 {
			fmt.Fprintln(os.Stderr, airUsage)
			os.Exit(2)
		}
		value, err := loadConfig(configPath)
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		client := memberClient{config: value, signer: key, http: httpClient, now: time.Now, nonce: randomNonce}
		if os.Args[1] == "approval-status" {
			registered, digest, err := client.approvalKeyStatus()
			if err != nil {
				fmt.Fprintln(os.Stderr, "Error:", err)
				os.Exit(2)
			}
			encoded, _ := json.Marshal(map[string]any{"registered": registered, "public_key_sha256": digest})
			fmt.Println(string(encoded))
			return
		}
		var privateKey *ecdsa.PrivateKey
		if os.Args[1] == "approval-init" {
			password, err := readPassword("设置两头乌高风险操作确认码（输入四个空格）: ")
			if err != nil {
				fmt.Fprintln(os.Stderr, "Error:", err)
				os.Exit(2)
			}
			repeated, err := readPassword("再次输入确认密码: ")
			if err != nil || !hmac.Equal(password, repeated) {
				wipe(password)
				wipe(repeated)
				fmt.Fprintln(os.Stderr, "Error: 两次输入的确认码不一致")
				os.Exit(2)
			}
			stored, created, err := encryptApprovalPrivateKey(password)
			wipe(password)
			wipe(repeated)
			if err == nil {
				err = saveEncryptedApprovalKey(approvalKeyPath(configPath), stored)
			}
			if err != nil {
				fmt.Fprintln(os.Stderr, "Error:", err)
				os.Exit(2)
			}
			privateKey = created
		} else {
			password, err := readPassword("两头乌高风险操作确认码（输入四个空格）: ")
			if err != nil {
				fmt.Fprintln(os.Stderr, "Error:", err)
				os.Exit(2)
			}
			stored, loadErr := loadEncryptedApprovalKey(approvalKeyPath(configPath))
			if loadErr == nil {
				privateKey, loadErr = decryptApprovalPrivateKey(stored, password)
			}
			wipe(password)
			if loadErr != nil {
				fmt.Fprintln(os.Stderr, "Error:", loadErr)
				os.Exit(2)
			}
		}
		digest, err := client.registerApprovalKey(privateKey)
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			if os.Args[1] == "approval-init" {
				fmt.Fprintln(os.Stderr, "本地审批钥匙已保存；网络恢复后运行 approval-register。")
			}
			os.Exit(2)
		}
		encoded, _ := json.Marshal(map[string]string{"result": "registered", "public_key_sha256": digest})
		fmt.Println(string(encoded))
		return
	}
	command := os.Args[1]
	validShape := (command == "diagnose" && len(os.Args) == 2) ||
		(command == "modules" && len(os.Args) == 2) ||
		(command == "module-pull" && len(os.Args) == 3) ||
		(command == "fetch" && len(os.Args) == 3) ||
		(command == "interactions" && len(os.Args) == 3) ||
		(command == "reply" && len(os.Args) == 5) ||
		(command == "answer" && len(os.Args) >= 6 && os.Args[4] == "--")
	if !validShape {
		fmt.Fprintln(os.Stderr, airUsage)
		os.Exit(2)
	}
	value, err := loadConfig(configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Error:", err)
		os.Exit(2)
	}
	client := memberClient{
		config: value, signer: key,
		http: httpClient, now: time.Now, nonce: randomNonce,
	}
	switch command {
	case "diagnose":
		identity, err := client.diagnose()
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		encoded, _ := json.Marshal(map[string]any{
			"result": "ok", "user_id": identity.User.ID, "device_id": identity.Device.ID,
			"platform": identity.Device.Platform, "codex_binding_id": identity.CodexBinding.ID,
		})
		fmt.Println(string(encoded))
	case "modules":
		directory, err := client.modules()
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		encoded, _ := json.Marshal(map[string]any{
			"platform": platformModuleNote(), "modules": printableModules(directory),
		})
		fmt.Println(string(encoded))
	case "module-pull":
		path, err := client.pullModule(os.Args[2])
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		encoded, _ := json.Marshal(map[string]string{"result": "installed", "module_id": os.Args[2], "path": path})
		fmt.Println(string(encoded))
	case "interactions":
		interactions, err := client.listInteractions(os.Args[2])
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		encoded, _ := json.Marshal(map[string]any{"interactions": interactions})
		fmt.Println(string(encoded))
	case "reply":
		interaction, err := client.replyInteraction(os.Args[2], os.Args[3], os.Args[4], "")
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		encoded, _ := json.Marshal(map[string]any{"interaction": interaction})
		fmt.Println(string(encoded))
	case "answer":
		answer := strings.Join(os.Args[5:], " ")
		interaction, err := client.replyInteraction(os.Args[2], os.Args[3], "answer", answer)
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		encoded, _ := json.Marshal(map[string]any{"interaction": interaction})
		fmt.Println(string(encoded))
	case "fetch":
		path, err := client.fetchResult(os.Args[2])
		if err != nil {
			fmt.Fprintln(os.Stderr, "Error:", err)
			os.Exit(2)
		}
		fmt.Println(path)
	}
}
