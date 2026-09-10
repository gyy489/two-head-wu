package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type fixtureSigner struct {
	mu       sync.Mutex
	messages []string
}

type fixtureHardwareKey struct {
	fixtureSigner
	material keyMaterial
	created  int
}

func (k *fixtureHardwareKey) Create() (keyMaterial, error) {
	k.created++
	return k.material, nil
}

func fixtureKeyMaterial(t *testing.T, provider string) keyMaterial {
	t.Helper()
	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(&privateKey.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return keyMaterial{Provider: provider, PublicKeySPKIBase64: base64.StdEncoding.EncodeToString(der)}
}

func (s *fixtureSigner) Sign(message []byte) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.messages = append(s.messages, string(message))
	return base64.StdEncoding.EncodeToString([]byte("fixture-signature")), nil
}

func fixtureClient(t *testing.T, result []byte, advertisedDigest string) (*memberClient, *int, *bool, string, func()) {
	t.Helper()
	const jobID = "job-member-review0001"
	const leaseID = "content-member-result001"
	reviewRoot := t.TempDir()
	receipts := 0
	filePresentAtReceipt := false
	digest := sha256.Sum256(result)
	actualDigest := hex.EncodeToString(digest[:])
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.Header.Get("X-Wu-User") != "usr-member-review001" || request.Header.Get("X-Wu-Signature") == "" {
			http.Error(response, "unauthorized", http.StatusUnauthorized)
			return
		}
		response.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/two-head-wu/v2/jobs/" + jobID:
			json.NewEncoder(response).Encode(map[string]any{"job": map[string]any{
				"id": jobID, "state": "succeeded", "content_lease_ids": []string{leaseID},
			}})
		case "/two-head-wu/v2/content/" + leaseID:
			json.NewEncoder(response).Encode(map[string]any{"content_lease": map[string]any{
				"id": leaseID, "job_id": jobID, "kind": "result-package", "state": "available",
				"sha256": advertisedDigest, "size": len(result),
			}})
		case "/two-head-wu/v2/jobs/" + jobID + "/result":
			response.Header().Set("Content-Type", "application/gzip")
			response.Write(result)
		case "/two-head-wu/v2/content/" + leaseID + "/receipt":
			receipts++
			filePresentAtReceipt = fileExists(filepath.Join(reviewRoot, jobID, "result-"+actualDigest[:12]+".tar.gz"))
			body, _ := io.ReadAll(request.Body)
			if !strings.Contains(string(body), actualDigest) {
				http.Error(response, "bad receipt", http.StatusBadRequest)
				return
			}
			json.NewEncoder(response).Encode(map[string]any{"content_lease": map[string]any{
				"id": leaseID, "job_id": jobID, "kind": "result-package", "state": "purged",
				"sha256": actualDigest, "size": len(result),
			}})
		default:
			http.NotFound(response, request)
		}
	}))
	signer := &fixtureSigner{}
	client := &memberClient{
		config: config{
			SchemaVersion: 2, Endpoint: server.URL + "/two-head-wu/v2",
			UserID: "usr-member-review001", DeviceID: "dev-member-review001", ReviewRoot: reviewRoot,
		},
		signer: signer, http: server.Client(), allowHTTP: true,
		now:   func() time.Time { return time.Unix(1_800_000_000, 0) },
		nonce: func() (string, error) { return "0123456789abcdef0123456789abcdef", nil },
	}
	return client, &receipts, &filePresentAtReceipt, jobID, server.Close
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func TestApprovalKeyEncryptionAndExactActionSignature(t *testing.T) {
	password := []byte(ownerConfirmationCode)
	stored, created, err := encryptApprovalPrivateKey(password)
	if err != nil {
		t.Fatalf("approval key creation failed: %v", err)
	}
	encoded, _ := json.Marshal(stored)
	if bytes.Contains(encoded, password) || bytes.Contains(encoded, []byte("private_key")) {
		t.Fatalf("encrypted approval key file exposed password or private-key fields")
	}
	loaded, err := decryptApprovalPrivateKey(stored, password)
	if err != nil {
		t.Fatalf("approval key decryption failed: %v", err)
	}
	createdPublic, _ := x509.MarshalPKIXPublicKey(&created.PublicKey)
	loadedPublic, _ := x509.MarshalPKIXPublicKey(&loaded.PublicKey)
	if !bytes.Equal(createdPublic, loadedPublic) {
		t.Fatalf("decrypted approval key does not match the created key")
	}
	if _, err := decryptApprovalPrivateKey(stored, []byte("   ")); err == nil {
		t.Fatalf("wrong owner confirmation code decrypted the key")
	}

	path := filepath.Join(t.TempDir(), "approval-key.json")
	if err := saveEncryptedApprovalKey(path, stored); err != nil {
		t.Fatalf("cannot save approval key: %v", err)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatalf("approval key file mode is %o, want 0600", info.Mode().Perm())
	}
	if _, err := loadEncryptedApprovalKey(path); err != nil {
		t.Fatalf("cannot reload approval key: %v", err)
	}

	value := config{UserID: "usr-owner-approval01", DeviceID: "dev-owner-approval01"}
	input := map[string]any{"artifact_sha256": strings.Repeat("a", 64), "site_id": "private-site"}
	now := time.Unix(1_800_000_000, 0)
	nonce := "0123456789abcdef0123456789abcdef"
	approval, err := buildApprovalEnvelope(
		loaded, value, "call-0123456789abcdef01234567", "workflow:publish-site", input, now, nonce,
	)
	if err != nil {
		t.Fatalf("cannot build exact owner approval: %v", err)
	}
	canonicalInput, _ := canonicalCapabilityInput(input)
	inputDigest := sha256.Sum256(canonicalInput)
	canonical := strings.Join([]string{
		approvalScheme,
		value.UserID,
		value.DeviceID,
		"call-0123456789abcdef01234567",
		"workflow:publish-site",
		hex.EncodeToString(inputDigest[:]),
		"1800000120",
		nonce,
	}, "\n")
	signature, _ := base64.StdEncoding.DecodeString(approval.SignatureBase64)
	digest := sha256.Sum256([]byte(canonical))
	if !ecdsa.VerifyASN1(&loaded.PublicKey, digest[:], signature) {
		t.Fatalf("owner approval did not sign its exact canonical action")
	}
	mutated := strings.Replace(canonical, hex.EncodeToString(inputDigest[:]), strings.Repeat("b", 64), 1)
	mutatedDigest := sha256.Sum256([]byte(mutated))
	if ecdsa.VerifyASN1(&loaded.PublicKey, mutatedDigest[:], signature) {
		t.Fatalf("owner approval signature survived a target mutation")
	}
}

func TestCapabilityInputCanonicalizationAndDLP(t *testing.T) {
	input, err := decodeCapabilityInput(`{"text":"你好<世界","action":"remember"}`)
	if err != nil {
		t.Fatalf("valid capability input was rejected: %v", err)
	}
	canonical, _ := canonicalCapabilityInput(input)
	if string(canonical) != `{"action":"remember","text":"你好<世界"}` {
		t.Fatalf("capability input is not deterministic UTF-8 JSON: %s", canonical)
	}
	secretShapedInput := `{"text":"` + "sk-" + strings.Repeat("x", 26) + `","action":"remember"}`
	if _, err := decodeCapabilityInput(secretShapedInput); err == nil {
		t.Fatalf("capability input secret DLP accepted a token-shaped value")
	}
}

func TestLegacyAirConfigMigratesOnceWithoutDualWrite(t *testing.T) {
	directory := t.TempDir()
	legacy := filepath.Join(directory, "member.json")
	current := filepath.Join(directory, "air.json")
	value := config{
		SchemaVersion: 2,
		Endpoint:      "https://relay.example/two-head-wu/v2",
		UserID:        "usr-config-migrate01",
		DeviceID:      "dev-config-migrate01",
	}
	if err := saveConfig(legacy, value); err != nil {
		t.Fatalf("cannot create legacy migration fixture: %v", err)
	}
	if err := migrateLegacyConfig(current, legacy); err != nil {
		t.Fatalf("legacy Air config migration failed: %v", err)
	}
	loaded, err := loadConfig(current)
	if err != nil || loaded != value {
		t.Fatalf("migrated Air config changed: %#v %v", loaded, err)
	}
	if _, err := os.Lstat(legacy); !os.IsNotExist(err) {
		t.Fatalf("legacy member.json remained after verified migration")
	}
	if err := migrateLegacyConfig(current, legacy); err != nil {
		t.Fatalf("Air config migration was not idempotent: %v", err)
	}
}

func TestEmbeddedReleaseKeyVerifiesBuiltAirModuleManifest(t *testing.T) {
	trackedKey, err := os.ReadFile(filepath.Join("..", "..", "keys", "release-signing-public.pub"))
	if err != nil || !bytes.Equal(trackedKey, embeddedReleasePublicKey) {
		t.Fatalf("native Air embedded release key drifted from the tracked public key")
	}
	manifestPath := filepath.Join("..", "..", "..", "..", "var", "remote-work", "build", "current", "components", "air-manifest.json")
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Skip("current built Air manifest is not available")
	}
	var manifest signedModuleManifest
	if json.Unmarshal(data, &manifest) != nil {
		t.Fatalf("current built Air manifest is invalid JSON")
	}
	if err := verifyModuleManifest(manifest, embeddedReleasePublicKey); err != nil {
		t.Fatalf("native client cannot verify the current signed Air manifest: %v", err)
	}
}

func TestEmbeddedReleaseKeyVerifiesBuiltAirCapabilityManifests(t *testing.T) {
	for _, name := range []string{"air-manifest.json", "owner-air-manifest.json"} {
		manifestPath := filepath.Join("..", "..", "..", "..", "var", "remote-work", "build", "current", "capabilities", name)
		data, err := os.ReadFile(manifestPath)
		if err != nil {
			t.Skip("current built Air capability manifests are not available")
		}
		manifest, capabilities, err := verifyCapabilityManifest(data, embeddedReleasePublicKey)
		if err != nil {
			t.Fatalf("native client cannot verify %s: %v", name, err)
		}
		if len(capabilities) == 0 || len(capabilities) != len(manifest.Capabilities) {
			t.Fatalf("native client did not preserve %s capability entries", name)
		}
		mutated := append([]byte(nil), data...)
		needle := []byte(`"confirmation": "none"`)
		if offset := bytes.Index(mutated, needle); offset >= 0 {
			copy(mutated[offset:offset+len(needle)], []byte(`"confirmation": "xxxx"`))
			if _, _, err := verifyCapabilityManifest(mutated, embeddedReleasePublicKey); err == nil {
				t.Fatalf("native client accepted a mutated signed capability manifest")
			}
		}
	}
}

func TestSkillArchiveRejectsLinksAndTraversal(t *testing.T) {
	buildArchive := func(name string, kind byte) []byte {
		var output bytes.Buffer
		gzipWriter := gzip.NewWriter(&output)
		tarWriter := tar.NewWriter(gzipWriter)
		_ = tarWriter.WriteHeader(&tar.Header{Name: name, Typeflag: kind, Mode: 0644, Size: 1, Linkname: "outside"})
		if kind == tar.TypeReg {
			_, _ = tarWriter.Write([]byte("x"))
		}
		_ = tarWriter.Close()
		_ = gzipWriter.Close()
		return output.Bytes()
	}
	for _, archive := range [][]byte{
		buildArchive("../escape", tar.TypeReg),
		buildArchive("SKILL.md", tar.TypeSymlink),
	} {
		if err := unpackSkillArchive(archive, t.TempDir()); err == nil {
			t.Fatalf("unsafe portable Skill archive was accepted")
		}
	}
}

func TestFetchResultWritesReviewCopyBeforeReceipt(t *testing.T) {
	result := []byte("review-only-result-package")
	digest := sha256.Sum256(result)
	client, receipts, presentAtReceipt, jobID, closeServer := fixtureClient(t, result, hex.EncodeToString(digest[:]))
	defer closeServer()

	path, err := client.fetchResult(jobID)
	if err != nil {
		t.Fatalf("fetchResult failed: %v", err)
	}
	if *receipts != 1 || !*presentAtReceipt {
		t.Fatalf("receipt was not sent exactly once after durable review write")
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != string(result) {
		t.Fatalf("review package was not preserved exactly")
	}
	if filepath.Ext(path) != ".gz" {
		t.Fatalf("result was not retained as a review archive")
	}
	entries, _ := os.ReadDir(filepath.Dir(path))
	if len(entries) != 1 {
		t.Fatalf("client unpacked or auto-applied review content")
	}
}

func capsuleFiles(t *testing.T, data []byte) map[string]string {
	t.Helper()
	reader, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	archive := tar.NewReader(reader)
	result := map[string]string{}
	for {
		header, err := archive.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if header.Typeflag == tar.TypeReg || header.Typeflag == tar.TypeRegA {
			body, err := io.ReadAll(archive)
			if err != nil {
				t.Fatal(err)
			}
			result[header.Name] = string(body)
		}
	}
	return result
}

func TestProjectCapsuleExcludesCredentialsDependenciesAndSymlinks(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "src"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "src", "main.txt"), []byte("safe source"), 0600); err != nil {
		t.Fatal(err)
	}
	for name := range map[string]bool{".env": true, ".env.production": true, ".npmrc": true, "id_ed25519": true, "device.key": true, "credentials.json": true, "auth-local.json": true} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("must not leave Air"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(root, "node_modules"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "node_modules", "package.js"), []byte("cache"), 0600); err != nil {
		t.Fatal(err)
	}
	_ = os.Symlink(filepath.Join(root, ".env"), filepath.Join(root, "src", "linked-secret"))
	capsule, digest, err := buildProjectCapsule(root)
	if err != nil {
		t.Fatalf("buildProjectCapsule failed: %v", err)
	}
	actual := sha256.Sum256(capsule)
	if digest != hex.EncodeToString(actual[:]) {
		t.Fatalf("capsule digest did not bind exact bytes")
	}
	files := capsuleFiles(t, capsule)
	if files["src/main.txt"] != "safe source" || len(files) != 1 {
		t.Fatalf("capsule included an excluded or linked path: %#v", files)
	}
	symlinkRoot := filepath.Join(t.TempDir(), "project-link")
	if os.Symlink(root, symlinkRoot) == nil {
		if _, _, err := buildProjectCapsule(symlinkRoot); err == nil || !strings.Contains(err.Error(), "symlink") {
			t.Fatalf("symlink project root was accepted: %v", err)
		}
	}
	forbiddenArtifact := filepath.Join(t.TempDir(), ".env.production")
	if err := os.WriteFile(forbiddenArtifact, []byte("secret"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readInputArtifact(forbiddenArtifact); err == nil || !strings.Contains(err.Error(), "credential-shaped") {
		t.Fatalf("credential-shaped explicit artifact was accepted: %v", err)
	}
	leakPath := filepath.Join(root, "src", "leak.txt")
	if err := os.WriteFile(leakPath, []byte("AKIA"+strings.Repeat("1", 16)), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := buildProjectCapsule(root); err == nil || !strings.Contains(err.Error(), "DLP") {
		t.Fatalf("secret-shaped project bytes were accepted: %v", err)
	}
	if err := os.Remove(leakPath); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(forbiddenArtifact, []byte("-----BEGIN "+"OPENSSH PRIVATE KEY-----"), 0600); err != nil {
		t.Fatal(err)
	}
	allowedName := filepath.Join(filepath.Dir(forbiddenArtifact), "notes.txt")
	if err := os.Rename(forbiddenArtifact, allowedName); err != nil {
		t.Fatal(err)
	}
	if _, err := readInputArtifact(allowedName); err == nil || !strings.Contains(err.Error(), "DLP") {
		t.Fatalf("secret-shaped artifact bytes were accepted: %v", err)
	}
}

func TestParseSubmitArgumentsAllowsRepeatedExplicitArtifacts(t *testing.T) {
	project, requestID, artifacts, instruction, err := parseSubmitArguments([]string{
		"--project", "/selected/project", "--artifact", "/selected/a.pdf", "--artifact", "/selected/b.docx",
		"--request-id", "call-1234567890abcdef12345678", "--", "review", "these", "files",
	})
	if err != nil || project != "/selected/project" || requestID != "call-1234567890abcdef12345678" ||
		strings.Join(artifacts, ",") != "/selected/a.pdf,/selected/b.docx" || instruction != "review these files" {
		t.Fatalf("explicit artifact arguments drifted: project=%q request=%q artifacts=%#v instruction=%q error=%v", project, requestID, artifacts, instruction, err)
	}
}

func TestSubmitProjectRecoversAfterActivationDisconnectAndIsIdempotent(t *testing.T) {
	const requestID = "call-aaaaaaaaaaaaaaaaaaaaaaaa"
	const jobID = "job-member-submit0001"
	const leaseID = "content-member-submit001"
	project := t.TempDir()
	if err := os.WriteFile(filepath.Join(project, "paper.md"), []byte("draft"), 0600); err != nil {
		t.Fatal(err)
	}
	artifactPath := filepath.Join(t.TempDir(), "notes.txt")
	if err := os.WriteFile(artifactPath, []byte("selected notes"), 0600); err != nil {
		t.Fatal(err)
	}
	state := "staging"
	activationAttempts := 0
	requests := []string{}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests = append(requests, request.Method+" "+request.URL.Path)
		response.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/two-head-wu/v2/jobs/draft":
			json.NewEncoder(response).Encode(map[string]any{"job": map[string]any{
				"id": jobID, "state": state, "content_lease_ids": []string{},
			}})
		case "/two-head-wu/v2/jobs/" + jobID + "/content":
			if state != "staging" {
				http.Error(response, "already queued", http.StatusConflict)
				return
			}
			var payload map[string]any
			if json.NewDecoder(request.Body).Decode(&payload) != nil {
				http.Error(response, "bad content", http.StatusBadRequest)
				return
			}
			encoded, _ := payload["content_base64"].(string)
			content, err := base64.StdEncoding.DecodeString(encoded)
			kind, _ := payload["kind"].(string)
			if kind == "project-capsule" {
				if payload["request_id"] != capsuleRequestID(requestID) || err != nil || capsuleFiles(t, content)["paper.md"] != "draft" {
					http.Error(response, "unsafe capsule", http.StatusBadRequest)
					return
				}
			} else if kind == "input-artifact" {
				if payload["request_id"] != artifactRequestID(requestID, 0) || payload["filename"] != "notes.txt" || string(content) != "selected notes" {
					http.Error(response, "bad artifact", http.StatusBadRequest)
					return
				}
			} else {
				http.Error(response, "bad kind", http.StatusBadRequest)
				return
			}
			json.NewEncoder(response).Encode(map[string]any{"content_lease": map[string]any{
				"id":     map[string]string{"project-capsule": leaseID, "input-artifact": "content-member-input0001"}[kind],
				"job_id": jobID, "kind": kind, "state": "available",
				"sha256": payload["sha256"], "size": len(content),
			}})
		case "/two-head-wu/v2/jobs/" + jobID + "/submit":
			activationAttempts++
			if activationAttempts == 1 {
				http.Error(response, "temporary relay interruption", http.StatusServiceUnavailable)
				return
			}
			state = "queued"
			json.NewEncoder(response).Encode(map[string]any{"job": map[string]any{
				"id": jobID, "state": state, "content_lease_ids": []string{leaseID},
			}})
		default:
			http.NotFound(response, request)
		}
	}))
	defer server.Close()
	client := &memberClient{
		config: config{SchemaVersion: 2, Endpoint: server.URL + "/two-head-wu/v2", UserID: "usr-member-submit001", DeviceID: "dev-member-submit001"},
		signer: &fixtureSigner{}, http: server.Client(), allowHTTP: true,
		now:   func() time.Time { return time.Unix(1_800_000_000, 0) },
		nonce: func() (string, error) { return "0123456789abcdef0123456789abcdef", nil },
	}
	job, err := client.submitProject(project, "review the selected project", requestID, []string{artifactPath})
	if err == nil || job.ID != jobID || job.State != "staging" {
		t.Fatalf("activation interruption did not preserve a recoverable draft: job=%#v error=%v", job, err)
	}
	expected := []string{
		"POST /two-head-wu/v2/jobs/draft",
		"POST /two-head-wu/v2/jobs/" + jobID + "/content",
		"POST /two-head-wu/v2/jobs/" + jobID + "/content",
		"POST /two-head-wu/v2/jobs/" + jobID + "/submit",
	}
	if strings.Join(requests, "\n") != strings.Join(expected, "\n") {
		t.Fatalf("draft/content/submit order drifted: %#v", requests)
	}
	job, err = client.submitProject(project, "review the selected project", requestID, []string{artifactPath})
	if err != nil || job.State != "queued" || len(requests) != 8 ||
		strings.Join(requests[4:], "\n") != strings.Join(expected, "\n") {
		t.Fatalf("recoverable submit did not restage content safely: job=%#v requests=%#v error=%v", job, requests, err)
	}
	job, err = client.submitProject(project, "review the selected project", requestID, []string{artifactPath})
	if err != nil || job.State != "queued" || len(requests) != 9 || requests[8] != expected[0] {
		t.Fatalf("idempotent submit repeated content or activation: job=%#v requests=%#v error=%v", job, requests, err)
	}
}

func TestMemberInteractionsStayTenantBoundAndRequireExplicitSafeReply(t *testing.T) {
	const jobID = "job-member-interact001"
	const approvalID = "ask-0123456789abcdef"
	const inputID = "ask-fedcba9876543210"
	const userID = "usr-member-interact01"
	requests := 0
	interaction := func(id, kind string) map[string]any {
		return map[string]any{
			"schema_version": 2, "id": id, "user_id": userID, "job_id": jobID,
			"kind": kind, "state": "pending", "title": "Review this request",
			"detail": "Untrusted task text is display-only.", "action_sha256": strings.Repeat("a", 64),
			"created_at": "2027-01-15T08:00:00Z", "expires_at": "2027-01-15T08:10:00Z",
		}
	}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests++
		response.Header().Set("Content-Type", "application/json")
		switch request.Method + " " + request.URL.Path {
		case "GET /two-head-wu/v2/jobs/" + jobID + "/interactions":
			json.NewEncoder(response).Encode(map[string]any{"interactions": []any{
				interaction(approvalID, "command-approval"), interaction(inputID, "user-input"),
			}})
		case "POST /two-head-wu/v2/jobs/" + jobID + "/interactions/" + approvalID + "/reply":
			var payload map[string]string
			if json.NewDecoder(request.Body).Decode(&payload) != nil || payload["decision"] != "accept" || len(payload) != 1 {
				http.Error(response, "invalid approval", http.StatusBadRequest)
				return
			}
			value := interaction(approvalID, "command-approval")
			value["state"] = "answered"
			value["reply"] = map[string]string{"decision": "accept"}
			value["replied_at"] = "2027-01-15T08:01:00Z"
			json.NewEncoder(response).Encode(map[string]any{"interaction": value})
		case "POST /two-head-wu/v2/jobs/" + jobID + "/interactions/" + inputID + "/reply":
			var payload map[string]string
			if json.NewDecoder(request.Body).Decode(&payload) != nil || payload["decision"] != "answer" || payload["answer"] != "Use the public appendix." {
				http.Error(response, "invalid answer", http.StatusBadRequest)
				return
			}
			value := interaction(inputID, "user-input")
			value["state"] = "answered"
			value["reply"] = map[string]string{"decision": "answer", "answer": payload["answer"]}
			value["replied_at"] = "2027-01-15T08:02:00Z"
			json.NewEncoder(response).Encode(map[string]any{"interaction": value})
		default:
			http.NotFound(response, request)
		}
	}))
	defer server.Close()
	client := &memberClient{
		config: config{SchemaVersion: 2, Endpoint: server.URL + "/two-head-wu/v2", UserID: userID, DeviceID: "dev-member-interact01"},
		signer: &fixtureSigner{}, http: server.Client(), allowHTTP: true,
		now:   func() time.Time { return time.Unix(1_800_000_000, 0) },
		nonce: func() (string, error) { return "0123456789abcdef0123456789abcdef", nil },
	}
	listed, err := client.listInteractions(jobID)
	if err != nil || len(listed) != 2 || listed[0].ID != approvalID || listed[1].ID != inputID {
		t.Fatalf("member interaction list drifted: interactions=%#v error=%v", listed, err)
	}
	approved, err := client.replyInteraction(jobID, approvalID, "accept", "")
	if err != nil || approved.State != "answered" || approved.Reply == nil || approved.Reply.Decision != "accept" {
		t.Fatalf("explicit command approval failed: interaction=%#v error=%v", approved, err)
	}
	answered, err := client.replyInteraction(jobID, inputID, "answer", "Use the public appendix.")
	if err != nil || answered.Reply == nil || answered.Reply.Answer != "Use the public appendix." {
		t.Fatalf("explicit user answer failed: interaction=%#v error=%v", answered, err)
	}
	requestsBeforeDLP := requests
	if _, err := client.replyInteraction(jobID, inputID, "answer", "-----BEGIN "+"PRIVATE KEY-----"); err == nil || !strings.Contains(err.Error(), "DLP") {
		t.Fatalf("secret-shaped interaction answer was accepted: %v", err)
	}
	if requests != requestsBeforeDLP {
		t.Fatalf("secret-shaped interaction answer reached the relay")
	}
}

func TestMemberInteractionRejectsWorkerLeaseLeakAndCrossTenantIdentity(t *testing.T) {
	value := memberInteraction{
		SchemaVersion: 2, ID: "ask-0123456789abcdef", UserID: "usr-member-interact01",
		JobID: "job-member-interact001", ExecutionLeaseID: "work-0123456789abcdef01234567",
		Kind: "command-approval", State: "pending", Title: "Review", Detail: "Display only",
		ActionSHA256: strings.Repeat("a", 64), CreatedAt: "2027-01-15T08:00:00Z", ExpiresAt: "2027-01-15T08:10:00Z",
	}
	if err := validateMemberInteraction(value, value.UserID, value.JobID); err == nil || !strings.Contains(err.Error(), "identity") {
		t.Fatalf("worker execution lease leaked through member interaction: %v", err)
	}
	value.ExecutionLeaseID = ""
	if err := validateMemberInteraction(value, "usr-member-different1", value.JobID); err == nil || !strings.Contains(err.Error(), "identity") {
		t.Fatalf("cross-tenant interaction identity was accepted: %v", err)
	}
}

func TestFetchResultRejectsHashMismatchWithoutReceipt(t *testing.T) {
	client, receipts, _, jobID, closeServer := fixtureClient(t, []byte("tampered"), strings.Repeat("a", 64))
	defer closeServer()
	if _, err := client.fetchResult(jobID); err == nil || !strings.Contains(err.Error(), "hash") {
		t.Fatalf("hash mismatch was not rejected: %v", err)
	}
	if *receipts != 0 {
		t.Fatalf("hash mismatch sent a receipt")
	}
	entries, _ := os.ReadDir(client.config.ReviewRoot)
	if len(entries) != 0 {
		t.Fatalf("hash mismatch left review content")
	}
}

func TestRequestRequiresHTTPSOutsideTests(t *testing.T) {
	client := &memberClient{
		config: config{Endpoint: "http://127.0.0.1/two-head-wu/v2", UserID: "usr-member-review001", DeviceID: "dev-member-review001"},
		signer: &fixtureSigner{}, http: http.DefaultClient, now: time.Now,
		nonce: func() (string, error) { return "0123456789abcdef0123456789abcdef", nil },
	}
	if _, err := client.request(http.MethodGet, "/me", nil); err == nil || !strings.Contains(err.Error(), "HTTPS") {
		t.Fatalf("plaintext endpoint was accepted: %v", err)
	}
}

func TestDiagnoseRequiresSignedActiveDeviceAndFixedBinding(t *testing.T) {
	platform, _, err := platformIdentity()
	if err != nil {
		t.Skip("native member diagnosis is supported only on macOS and Windows")
	}
	revoked := false
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/two-head-wu/v2/me" || request.Header.Get("X-Wu-Signature") == "" {
			http.Error(response, "unauthorized", http.StatusUnauthorized)
			return
		}
		status := "active"
		if revoked {
			status = "revoked"
		}
		response.Header().Set("Content-Type", "application/json")
		json.NewEncoder(response).Encode(map[string]any{
			"user": map[string]string{"id": "usr-member-diagnose1", "role": "member", "status": "active"},
			"device": map[string]string{
				"id": "dev-member-diagnose1", "role": "air", "platform": platform, "status": status,
			},
			"codex_binding": map[string]string{"id": "cdx-member-diagnose1", "status": "active"},
		})
	}))
	defer server.Close()
	client := &memberClient{
		config: config{SchemaVersion: 2, Endpoint: server.URL + "/two-head-wu/v2", UserID: "usr-member-diagnose1", DeviceID: "dev-member-diagnose1"},
		signer: &fixtureSigner{}, http: server.Client(), allowHTTP: true,
		now:   func() time.Time { return time.Unix(1_800_000_000, 0) },
		nonce: func() (string, error) { return "0123456789abcdef0123456789abcdef", nil },
	}
	identity, err := client.diagnose()
	if err != nil || identity.Device.Platform != platform || identity.CodexBinding.Status != "active" {
		t.Fatalf("active member diagnosis failed: identity=%#v error=%v", identity, err)
	}
	revoked = true
	if _, err := client.diagnose(); err == nil || !strings.Contains(err.Error(), "diagnosis failed") {
		t.Fatalf("revoked member device passed diagnosis: %v", err)
	}
}

func TestReviewRetryAcceptsIdenticalFileAndRejectsConflict(t *testing.T) {
	path := filepath.Join(t.TempDir(), "result.tar.gz")
	result := []byte("durable-review-result")
	digest := sha256.Sum256(result)
	digestText := hex.EncodeToString(digest[:])
	if err := persistReviewFile(path, result, digestText); err != nil {
		t.Fatalf("initial review write failed: %v", err)
	}
	if err := persistReviewFile(path, result, digestText); err != nil {
		t.Fatalf("identical receipt retry was rejected: %v", err)
	}
	if err := os.WriteFile(path, []byte("local-conflict"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := persistReviewFile(path, result, digestText); err == nil || !strings.Contains(err.Error(), "does not match") {
		t.Fatalf("conflicting review file was overwritten or ambiguously rejected: %v", err)
	}
}

func TestCanonicalRequestBindsPathBodyAndPrincipal(t *testing.T) {
	result := []byte("canonical-result")
	digest := sha256.Sum256(result)
	client, _, _, jobID, closeServer := fixtureClient(t, result, hex.EncodeToString(digest[:]))
	defer closeServer()
	signer := client.signer.(*fixtureSigner)
	if _, err := client.fetchResult(jobID); err != nil {
		t.Fatalf("fetchResult failed: %v", err)
	}
	signer.mu.Lock()
	defer signer.mu.Unlock()
	if len(signer.messages) < 4 {
		t.Fatalf("not every request was signed")
	}
	for _, message := range signer.messages {
		if !strings.HasPrefix(message, authScheme+"\n") || !strings.Contains(message, "\nusr-member-review001\ndev-member-review001\n") {
			t.Fatalf("canonical request lost its principal binding")
		}
	}
}

func TestEnrollmentCreatesHardwareKeyAndPersistsOnlyPublicConfiguration(t *testing.T) {
	token := "pair-" + strings.Repeat("a", 43)
	tokenDigest := sha256.Sum256([]byte(token))
	material := fixtureKeyMaterial(t, "secure-enclave")
	key := &fixtureHardwareKey{material: material}
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/two-head-wu/v2/enroll" || request.Header.Get("Authorization") != "MemberEnrollment "+token {
			http.Error(response, "unauthorized", http.StatusUnauthorized)
			return
		}
		var payload map[string]string
		if json.NewDecoder(request.Body).Decode(&payload) != nil || payload["public_key_spki_base64"] != material.PublicKeySPKIBase64 {
			http.Error(response, "bad enrollment", http.StatusBadRequest)
			return
		}
		response.Header().Set("Content-Type", "application/json")
		response.WriteHeader(http.StatusCreated)
		json.NewEncoder(response).Encode(map[string]any{"device": map[string]string{
			"id": "dev-member-enrollment001", "user_id": "usr-member-enrollment001",
			"role": "air", "platform": "macos", "status": "active",
		}})
	}))
	defer server.Close()
	value, err := enrollMember(
		server.URL+"/two-head-wu/v2", token, t.TempDir(), "macos", "secure-enclave",
		key, server.Client(), func() time.Time { return time.Unix(1_800_000_000, 0) },
		func() (string, error) { return strings.Repeat("b", 32), nil }, true,
	)
	if err != nil {
		t.Fatalf("enrollment failed: %v", err)
	}
	if key.created != 1 || len(key.messages) != 1 {
		t.Fatalf("hardware proof was not created and signed exactly once")
	}
	canonical := key.messages[0]
	if strings.Contains(canonical, token) || !strings.Contains(canonical, hex.EncodeToString(tokenDigest[:])) ||
		!strings.Contains(canonical, material.PublicKeySPKIBase64) {
		t.Fatalf("enrollment canonical message leaked the token or lost its binding")
	}
	path := filepath.Join(t.TempDir(), "member.json")
	if err := saveConfig(path, value); err != nil {
		t.Fatalf("config save failed: %v", err)
	}
	data, err := os.ReadFile(path)
	if err != nil || strings.Contains(string(data), token) || strings.Contains(string(data), "private") {
		t.Fatalf("saved configuration contains enrollment or private material")
	}
	if loaded, err := loadConfig(path); err != nil || loaded.UserID != "usr-member-enrollment001" {
		t.Fatalf("saved configuration cannot be loaded: %v", err)
	}
}

func TestEnrollmentRejectsPlaintextBeforeCreatingKey(t *testing.T) {
	key := &fixtureHardwareKey{material: fixtureKeyMaterial(t, "secure-enclave")}
	_, err := enrollMember(
		"http://relay.example/two-head-wu/v2", "pair-"+strings.Repeat("a", 43), "",
		"macos", "secure-enclave", key, http.DefaultClient, time.Now, randomNonce, false,
	)
	if err == nil || !strings.Contains(err.Error(), "HTTPS") || key.created != 0 {
		t.Fatalf("plaintext enrollment reached hardware key creation: %v", err)
	}
}

func TestSaveConfigRefusesToOverwriteExistingBinding(t *testing.T) {
	path := filepath.Join(t.TempDir(), "member.json")
	value := config{
		SchemaVersion: 2, Endpoint: "https://relay.example/two-head-wu/v2",
		UserID: "usr-member-existing001", DeviceID: "dev-member-existing001",
	}
	if err := saveConfig(path, value); err != nil {
		t.Fatal(err)
	}
	original, _ := os.ReadFile(path)
	value.DeviceID = "dev-member-replacement01"
	if err := saveConfig(path, value); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("existing member binding was overwritten or ambiguously rejected: %v", err)
	}
	after, _ := os.ReadFile(path)
	if string(original) != string(after) {
		t.Fatalf("existing member configuration changed")
	}
}

func TestProductionClientRefusesRedirects(t *testing.T) {
	redirected := false
	target := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		redirected = true
		response.WriteHeader(http.StatusOK)
	}))
	defer target.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		http.Redirect(response, &http.Request{}, target.URL, http.StatusTemporaryRedirect)
	}))
	defer origin.Close()
	response, err := productionHTTPClient().Get(origin.URL)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != http.StatusTemporaryRedirect || redirected {
		t.Fatalf("production client followed a redirect")
	}
}
