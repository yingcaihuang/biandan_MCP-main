package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"os"
	"regexp"
	"strings"
	"sync"
)

// 密钥文件每行一把：「角色 名称 sha256:哈希」，# 开头是注释。服务端只存哈希，不存密钥本身。
//
//	push mac sha256:9f86d0…
//	read esp32-kitchen sha256:2c26b4…

var keyNamePattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

type keyEntry struct {
	role string
	name string
	hash [32]byte
}

type keyring struct {
	path    string
	mu      sync.RWMutex
	entries []keyEntry
}

func newKeyring(path string) (*keyring, error) {
	k := &keyring{path: path}
	if err := k.reload(); err != nil {
		return nil, err
	}
	return k, nil
}

func (k *keyring) reload() error {
	data, err := os.ReadFile(k.path)
	if err != nil {
		return fmt.Errorf("读取密钥文件 %s：%w", k.path, err)
	}
	entries, err := parseKeys(data)
	if err != nil {
		return fmt.Errorf("密钥文件 %s：%w", k.path, err)
	}
	k.mu.Lock()
	k.entries = entries
	k.mu.Unlock()
	return nil
}

func parseKeys(data []byte) ([]keyEntry, error) {
	var entries []keyEntry
	seen := map[string]bool{}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	line := 0
	for scanner.Scan() {
		line++
		text := strings.TrimSpace(scanner.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		fields := strings.Fields(text)
		if len(fields) != 3 {
			return nil, fmt.Errorf("第 %d 行应为「角色 名称 sha256:哈希」", line)
		}
		role, name, digest := fields[0], fields[1], fields[2]
		if role != "push" && role != "read" {
			return nil, fmt.Errorf("第 %d 行的角色只能是 push 或 read", line)
		}
		if !keyNamePattern.MatchString(name) {
			return nil, fmt.Errorf("第 %d 行的名称只能用字母、数字、点、下划线、短横线", line)
		}
		hexPart, ok := strings.CutPrefix(digest, "sha256:")
		raw, err := hex.DecodeString(hexPart)
		if !ok || err != nil || len(raw) != sha256.Size {
			return nil, fmt.Errorf("第 %d 行的哈希应为 sha256: 加 64 位十六进制", line)
		}
		id := role + "/" + name
		if seen[id] {
			return nil, fmt.Errorf("第 %d 行和前面重名：%s", line, id)
		}
		seen[id] = true
		entry := keyEntry{role: role, name: name}
		copy(entry.hash[:], raw)
		entries = append(entries, entry)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return entries, nil
}

func hashKey(token string) [32]byte { return sha256.Sum256([]byte(token)) }

// match 返回与 token 对应、角色为 role 的密钥名称。逐个比较全部条目，耗时与是否命中无关。
func (k *keyring) match(role, token string) (string, bool) {
	if token == "" || len(token) > 256 {
		return "", false
	}
	digest := hashKey(token)
	k.mu.RLock()
	defer k.mu.RUnlock()
	found := ""
	for _, entry := range k.entries {
		if subtle.ConstantTimeCompare(digest[:], entry.hash[:]) == 1 && entry.role == role {
			found = entry.name
		}
	}
	return found, found != ""
}

func (k *keyring) count(role string) int {
	k.mu.RLock()
	defer k.mu.RUnlock()
	n := 0
	for _, entry := range k.entries {
		if entry.role == role {
			n++
		}
	}
	return n
}
