package localserver

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
)

// PrivateDir rejects links and directories accessible to other accounts; local workflow history may contain project data.
func PrivateDir(path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("directory must be absolute")
	}
	if err := os.MkdirAll(path, 0700); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return errors.New("directory must be private")
	}
	return nil
}

// The same password must be reused for a persistent database. It is never passed on the command line.
func Password(dir string) (string, error) {
	if err := PrivateDir(dir); err != nil {
		return "", err
	}
	path := filepath.Join(dir, "database-secret")
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	generated := hex.EncodeToString(bytes)
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err == nil {
		_, writeErr := file.WriteString(generated)
		closeErr := file.Close()
		if writeErr != nil {
			return "", writeErr
		}
		if closeErr != nil {
			return "", closeErr
		}
		return generated, nil
	}
	if !os.IsExist(err) {
		return "", err
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return "", errors.New("database secret is not private")
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if len(contents) != 64 {
		return "", errors.New("database secret is invalid")
	}
	if _, err := hex.DecodeString(string(contents)); err != nil {
		return "", errors.New("database secret is invalid")
	}
	return string(contents), nil
}
