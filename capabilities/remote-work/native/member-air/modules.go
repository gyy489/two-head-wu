package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"time"
)

//go:embed release-signing-public.pub
var embeddedReleasePublicKey []byte

const managedModuleMarker = ".two-head-wu-module.json"

type moduleVersion struct {
	Version string `json:"version"`
	Archive string `json:"archive"`
	SHA256  string `json:"sha256"`
	Size    int64  `json:"size"`
}

type airModule struct {
	ID             string          `json:"id"`
	Classification string          `json:"classification"`
	Status         string          `json:"status"`
	Summary        string          `json:"summary"`
	DefaultMode    string          `json:"default_mode"`
	Version        string          `json:"version,omitempty"`
	Archive        string          `json:"archive,omitempty"`
	SHA256         string          `json:"sha256,omitempty"`
	Size           int64           `json:"size,omitempty"`
	Versions       []moduleVersion `json:"versions,omitempty"`
	Audience       string          `json:"audience,omitempty"`
}

type signedModuleManifest struct {
	SchemaVersion   int         `json:"schema_version"`
	GeneratedAt     string      `json:"generated_at"`
	Modules         []airModule `json:"modules"`
	PublicKeySHA256 string      `json:"public_key_sha256"`
	SignatureBase64 string      `json:"signature_base64,omitempty"`
}

type moduleDirectory struct {
	SchemaVersion    int                  `json:"schema_version"`
	Catalog          signedModuleManifest `json:"catalog"`
	EffectiveModules []string             `json:"effective_modules"`
}

type airCapability struct {
	ID           string `json:"id"`
	Status       string `json:"status"`
	Audience     string `json:"audience"`
	Confirmation string `json:"confirmation"`
}

type signedCapabilityManifest struct {
	SchemaVersion   int               `json:"schema_version"`
	CatalogVersion  string            `json:"catalog_version"`
	GeneratedAt     string            `json:"generated_at"`
	Capabilities    []json.RawMessage `json:"capabilities"`
	PublicKeySHA256 string            `json:"public_key_sha256"`
	SignatureBase64 string            `json:"signature_base64,omitempty"`
}

func releasePublicKey(value []byte) (*rsa.PublicKey, []byte, error) {
	block, rest := pem.Decode(value)
	if block == nil || block.Type != "PUBLIC KEY" || len(bytes.TrimSpace(rest)) != 0 {
		return nil, nil, errors.New("embedded module signing key is invalid")
	}
	parsed, err := x509.ParsePKIXPublicKey(block.Bytes)
	key, ok := parsed.(*rsa.PublicKey)
	if err != nil || !ok || key.N.BitLen() < 3072 || key.E != 65537 {
		return nil, nil, errors.New("embedded module signing key is invalid")
	}
	return key, block.Bytes, nil
}

func verifyModuleManifest(manifest signedModuleManifest, publicPEM []byte) error {
	if manifest.SchemaVersion != 2 || len(manifest.Modules) > 128 || manifest.SignatureBase64 == "" ||
		!hexPattern.MatchString(manifest.PublicKeySHA256) {
		return errors.New("signed Air module manifest is invalid")
	}
	if _, err := time.Parse(time.RFC3339, manifest.GeneratedAt); err != nil {
		return errors.New("signed Air module manifest has invalid time")
	}
	key, publicDER, err := releasePublicKey(publicPEM)
	if err != nil {
		return err
	}
	fingerprint := sha256.Sum256(publicDER)
	if !strings.EqualFold(hex.EncodeToString(fingerprint[:]), manifest.PublicKeySHA256) {
		return errors.New("Air module manifest signing key does not match the client pin")
	}
	seen := map[string]bool{}
	for _, item := range manifest.Modules {
		if seen[item.ID] || !capabilityIDPattern.MatchString(item.ID) ||
			(item.Classification != "portable" && item.Classification != "remote-only") ||
			(item.Status != "active" && item.Status != "disabled") || item.Summary == "" || len(item.Summary) > 2000 ||
			(item.Audience != "all-air" && item.Audience != "owner-air" && item.Audience != "owner-step-up") {
			return errors.New("Air module manifest contains an invalid entry")
		}
		seen[item.ID] = true
		if item.Classification == "portable" {
			if !regexp.MustCompile(`^[a-f0-9]{16}$`).MatchString(item.Version) || !hexPattern.MatchString(item.SHA256) ||
				item.Size < 1 || item.Size > maximumCapsuleBytes ||
				!regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,200}\.tar\.gz$`).MatchString(item.Archive) {
				return errors.New("Air module manifest contains an invalid portable release")
			}
		}
	}
	canonical := struct {
		SchemaVersion   int         `json:"schema_version"`
		GeneratedAt     string      `json:"generated_at"`
		Modules         []airModule `json:"modules"`
		PublicKeySHA256 string      `json:"public_key_sha256"`
	}{manifest.SchemaVersion, manifest.GeneratedAt, manifest.Modules, manifest.PublicKeySHA256}
	data, err := json.Marshal(canonical)
	if err != nil {
		return errors.New("cannot canonicalize Air module manifest")
	}
	signature, err := base64.StdEncoding.DecodeString(manifest.SignatureBase64)
	if err != nil || len(signature) != key.Size() {
		return errors.New("Air module manifest signature is invalid")
	}
	digest := sha256.Sum256(data)
	if rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], signature) != nil {
		return errors.New("Air module manifest signature is invalid")
	}
	return nil
}

func verifyCapabilityManifest(raw, publicPEM []byte) (signedCapabilityManifest, []airCapability, error) {
	if len(raw) < 2 || len(raw) > 2*1024*1024 {
		return signedCapabilityManifest{}, nil, errors.New("signed Air capability manifest is invalid")
	}
	var manifest signedCapabilityManifest
	if json.Unmarshal(raw, &manifest) != nil || manifest.SchemaVersion != 1 ||
		!regexp.MustCompile(`^[a-f0-9]{16}$`).MatchString(manifest.CatalogVersion) ||
		len(manifest.Capabilities) > 256 || manifest.SignatureBase64 == "" ||
		!hexPattern.MatchString(manifest.PublicKeySHA256) {
		return signedCapabilityManifest{}, nil, errors.New("signed Air capability manifest is invalid")
	}
	if _, err := time.Parse(time.RFC3339, manifest.GeneratedAt); err != nil {
		return signedCapabilityManifest{}, nil, errors.New("signed Air capability manifest has invalid time")
	}
	key, publicDER, err := releasePublicKey(publicPEM)
	if err != nil {
		return signedCapabilityManifest{}, nil, err
	}
	fingerprint := sha256.Sum256(publicDER)
	if !strings.EqualFold(hex.EncodeToString(fingerprint[:]), manifest.PublicKeySHA256) {
		return signedCapabilityManifest{}, nil, errors.New("Air capability manifest signing key does not match the client pin")
	}
	capabilities := make([]airCapability, 0, len(manifest.Capabilities))
	seen := map[string]bool{}
	for _, entry := range manifest.Capabilities {
		var capability airCapability
		if json.Unmarshal(entry, &capability) != nil || seen[capability.ID] ||
			!capabilityIDPattern.MatchString(capability.ID) ||
			(capability.Status != "active" && capability.Status != "disabled") ||
			(capability.Audience != "all-air" && capability.Audience != "owner-air" && capability.Audience != "owner-step-up") ||
			(capability.Confirmation != "none" && capability.Confirmation != "owner-password") {
			return signedCapabilityManifest{}, nil, errors.New("Air capability manifest contains an invalid entry")
		}
		seen[capability.ID] = true
		capabilities = append(capabilities, capability)
	}
	canonical := struct {
		SchemaVersion   int               `json:"schema_version"`
		CatalogVersion  string            `json:"catalog_version"`
		GeneratedAt     string            `json:"generated_at"`
		Capabilities    []json.RawMessage `json:"capabilities"`
		PublicKeySHA256 string            `json:"public_key_sha256"`
	}{manifest.SchemaVersion, manifest.CatalogVersion, manifest.GeneratedAt, manifest.Capabilities, manifest.PublicKeySHA256}
	var canonicalBuffer bytes.Buffer
	encoder := json.NewEncoder(&canonicalBuffer)
	encoder.SetEscapeHTML(false)
	if encoder.Encode(canonical) != nil {
		return signedCapabilityManifest{}, nil, errors.New("cannot canonicalize Air capability manifest")
	}
	canonicalData := bytes.TrimSuffix(canonicalBuffer.Bytes(), []byte("\n"))
	signature, err := base64.StdEncoding.DecodeString(manifest.SignatureBase64)
	if err != nil || len(signature) != key.Size() || base64.StdEncoding.EncodeToString(signature) != manifest.SignatureBase64 {
		return signedCapabilityManifest{}, nil, errors.New("Air capability manifest signature is invalid")
	}
	digest := sha256.Sum256(canonicalData)
	if rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], signature) != nil {
		return signedCapabilityManifest{}, nil, errors.New("Air capability manifest signature is invalid")
	}
	return manifest, capabilities, nil
}

func (c *memberClient) modules() (moduleDirectory, error) {
	response, err := c.request(http.MethodGet, "/modules", nil)
	if err != nil {
		return moduleDirectory{}, err
	}
	var directory moduleDirectory
	if err := decodeJSON(response, &directory); err != nil {
		return moduleDirectory{}, err
	}
	if directory.SchemaVersion != 2 || verifyModuleManifest(directory.Catalog, embeddedReleasePublicKey) != nil {
		return moduleDirectory{}, errors.New("relay returned an invalid signed Air module directory")
	}
	visible := map[string]bool{}
	for _, item := range directory.Catalog.Modules {
		visible[item.ID] = item.Status == "active"
	}
	if len(directory.EffectiveModules) > len(visible) {
		return moduleDirectory{}, errors.New("relay returned invalid effective Air modules")
	}
	for _, moduleID := range directory.EffectiveModules {
		if !visible[moduleID] {
			return moduleDirectory{}, errors.New("relay granted a missing or disabled Air module")
		}
	}
	return directory, nil
}

func (c *memberClient) pullModule(moduleID string) (string, error) {
	if !capabilityIDPattern.MatchString(moduleID) {
		return "", errors.New("invalid Air module id")
	}
	directory, err := c.modules()
	if err != nil {
		return "", err
	}
	granted := false
	for _, effective := range directory.EffectiveModules {
		granted = granted || effective == moduleID
	}
	var selected *airModule
	for index := range directory.Catalog.Modules {
		if directory.Catalog.Modules[index].ID == moduleID {
			selected = &directory.Catalog.Modules[index]
		}
	}
	if !granted || selected == nil || selected.Status != "active" || selected.Classification != "portable" {
		return "", errors.New("Air module is unavailable, remote-only, or not granted")
	}
	response, err := c.request(http.MethodGet, "/modules/"+moduleID+"/archive", nil)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("Air relay returned HTTP %d", response.StatusCode)
	}
	archive, err := io.ReadAll(io.LimitReader(response.Body, maximumCapsuleBytes+1))
	if err != nil || len(archive) < 1 || len(archive) > maximumCapsuleBytes || int64(len(archive)) != selected.Size {
		return "", errors.New("Air module archive size verification failed")
	}
	digest := sha256.Sum256(archive)
	if hex.EncodeToString(digest[:]) != selected.SHA256 {
		return "", errors.New("Air module archive digest verification failed")
	}
	target, err := installSkillModule(moduleID, selected.Version, selected.SHA256, archive)
	if err != nil {
		return "", err
	}
	return target, nil
}

func installSkillModule(moduleID, version, digest string, archive []byte) (string, error) {
	kind, name, found := strings.Cut(moduleID, ":")
	if !found || kind != "skill" || !regexp.MustCompile(`^[a-z][a-z0-9-]{0,62}$`).MatchString(name) {
		return "", errors.New("only portable Skill modules can be installed locally")
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", errors.New("cannot resolve Air home directory")
	}
	skillsRoot := filepath.Join(home, ".agents", "skills")
	if err := os.MkdirAll(skillsRoot, 0755); err != nil {
		return "", errors.New("cannot create the local Skill directory")
	}
	stage, err := os.MkdirTemp(skillsRoot, "."+name+".stage-")
	if err != nil {
		return "", errors.New("cannot stage the Air Skill module")
	}
	defer os.RemoveAll(stage)
	if err := unpackSkillArchive(archive, stage); err != nil {
		return "", err
	}
	if info, err := os.Stat(filepath.Join(stage, "SKILL.md")); err != nil || !info.Mode().IsRegular() {
		return "", errors.New("portable Skill module does not contain SKILL.md")
	}
	marker := map[string]any{
		"schema_version": 1, "module_id": moduleID, "version": version, "sha256": digest,
	}
	markerData, _ := json.Marshal(marker)
	if err := os.WriteFile(filepath.Join(stage, managedModuleMarker), append(markerData, '\n'), 0600); err != nil {
		return "", errors.New("cannot mark the managed Air Skill")
	}
	target := filepath.Join(skillsRoot, name)
	if existing, err := os.Lstat(target); err == nil {
		if !existing.IsDir() || existing.Mode()&os.ModeSymlink != 0 || !managedSkillMatches(target, moduleID) {
			return "", errors.New("local Skill target exists and is not managed by Two-Headed-Wu Air")
		}
		backup := target + ".before-" + fmt.Sprintf("%d", time.Now().UnixNano())
		if err := os.Rename(target, backup); err != nil {
			return "", errors.New("cannot stage the existing managed Air Skill")
		}
		if err := os.Rename(stage, target); err != nil {
			_ = os.Rename(backup, target)
			return "", errors.New("cannot activate the Air Skill module")
		}
		if err := os.RemoveAll(backup); err != nil {
			return target, errors.New("Air Skill installed but the previous managed version could not be removed")
		}
	} else if os.IsNotExist(err) {
		if err := os.Rename(stage, target); err != nil {
			return "", errors.New("cannot activate the Air Skill module")
		}
	} else {
		return "", errors.New("cannot inspect the local Skill target")
	}
	return target, nil
}

func managedSkillMatches(root, moduleID string) bool {
	data, err := os.ReadFile(filepath.Join(root, managedModuleMarker))
	if err != nil || len(data) > 4096 {
		return false
	}
	var marker struct {
		SchemaVersion int    `json:"schema_version"`
		ModuleID      string `json:"module_id"`
	}
	return json.Unmarshal(data, &marker) == nil && marker.SchemaVersion == 1 && marker.ModuleID == moduleID
}

func unpackSkillArchive(archive []byte, destination string) error {
	gzipReader, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return errors.New("Air Skill archive is not gzip")
	}
	defer gzipReader.Close()
	reader := tar.NewReader(gzipReader)
	total := int64(0)
	entries := 0
	seen := map[string]bool{}
	for {
		header, err := reader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return errors.New("Air Skill archive is invalid")
		}
		entries++
		if entries > maximumCapsuleEntries {
			return errors.New("Air Skill archive has too many entries")
		}
		name := filepath.Clean(filepath.FromSlash(header.Name))
		if name == "." || filepath.IsAbs(name) || name == ".." || strings.HasPrefix(name, ".."+string(filepath.Separator)) ||
			strings.ContainsRune(name, 0) || excludedProjectName(filepath.Base(name)) || seen[name] {
			return errors.New("Air Skill archive contains an unsafe path")
		}
		seen[name] = true
		target := filepath.Join(destination, name)
		prefix := filepath.Clean(destination) + string(filepath.Separator)
		if !strings.HasPrefix(filepath.Clean(target), prefix) {
			return errors.New("Air Skill archive escaped its staging directory")
		}
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0755); err != nil {
				return errors.New("cannot create Air Skill directory")
			}
		case tar.TypeReg, tar.TypeRegA:
			if header.Size < 0 || header.Size > maximumCapsuleBytes || total+header.Size > maximumCapsuleBytes {
				return errors.New("Air Skill archive exceeds its extraction limit")
			}
			total += header.Size
			if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
				return errors.New("cannot create Air Skill parent directory")
			}
			mode := os.FileMode(0644)
			if header.Mode&0111 != 0 {
				mode = 0755
			}
			file, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
			if err != nil {
				return errors.New("cannot create Air Skill file")
			}
			written, copyErr := io.CopyN(file, reader, header.Size)
			closeErr := file.Close()
			if copyErr != nil || closeErr != nil || written != header.Size {
				return errors.New("cannot extract Air Skill file")
			}
		default:
			return errors.New("Air Skill archive contains links or special files")
		}
	}
	if entries == 0 || total == 0 {
		return errors.New("Air Skill archive is empty")
	}
	return nil
}

func printableModules(directory moduleDirectory) []airModule {
	granted := map[string]bool{}
	for _, moduleID := range directory.EffectiveModules {
		granted[moduleID] = true
	}
	result := append([]airModule(nil), directory.Catalog.Modules...)
	sort.Slice(result, func(left, right int) bool { return result[left].ID < result[right].ID })
	for index := range result {
		if !granted[result[index].ID] && result[index].Status == "active" {
			result[index].Status = "not-granted"
		}
	}
	return result
}

func platformModuleNote() string {
	if runtime.GOOS == "windows" {
		return "Windows"
	}
	return "macOS"
}
