package localtls

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

// Files are ephemeral per app launch and must live in a private directory.
type Files struct {
	CA   string `json:"ca"`
	Cert string `json:"cert"`
	Key  string `json:"key"`
}

func Generate(dir string) (Files, error) {
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return Files{}, errors.New("TLS directory must be private")
	}
	now := time.Now()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return Files{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		return Files{}, err
	}
	caTemplate := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "MarkView local Temporal CA"}, NotBefore: now.Add(-time.Minute), NotAfter: now.AddDate(10, 0, 1), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		return Files{}, err
	}
	ca, err := x509.ParseCertificate(caDER)
	if err != nil {
		return Files{}, err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return Files{}, err
	}
	serial, err = rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		return Files{}, err
	}
	leaf := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "localhost"}, NotBefore: now.Add(-time.Minute), NotAfter: now.AddDate(10, 0, 0), DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth}}
	certDER, err := x509.CreateCertificate(rand.Reader, leaf, ca, &key.PublicKey, caKey)
	if err != nil {
		return Files{}, err
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return Files{}, err
	}
	result := Files{CA: filepath.Join(dir, "ca.pem"), Cert: filepath.Join(dir, "identity.pem"), Key: filepath.Join(dir, "identity-key.pem")}
	for _, item := range []struct {
		path  string
		block *pem.Block
	}{
		{result.CA, &pem.Block{Type: "CERTIFICATE", Bytes: caDER}}, {result.Cert, &pem.Block{Type: "CERTIFICATE", Bytes: certDER}}, {result.Key, &pem.Block{Type: "PRIVATE KEY", Bytes: keyDER}},
	} {
		f, err := os.OpenFile(item.path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return Files{}, err
		}
		err = pem.Encode(f, item.block)
		closeErr := f.Close()
		if err != nil {
			return Files{}, err
		}
		if closeErr != nil {
			return Files{}, closeErr
		}
	}
	return result, nil
}

func Client(files Files) (*tls.Config, error) {
	ca, err := os.ReadFile(files.CA)
	if err != nil {
		return nil, err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(ca) {
		return nil, errors.New("invalid local CA")
	}
	cert, err := tls.LoadX509KeyPair(files.Cert, files.Key)
	if err != nil {
		return nil, err
	}
	return &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots, Certificates: []tls.Certificate{cert}, ServerName: "localhost"}, nil
}
