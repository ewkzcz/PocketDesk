/**
 * 自签名证书与设备身份：首次启动生成，之后复用；手机端以证书指纹做固定校验。
 */
package security

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

/** Identity：电脑端证书与身份 */
type Identity struct {
	Cert        tls.Certificate
	Fingerprint string
}

/**
 * LoadOrCreateIdentity：读取已有证书，不存在则生成
 *
 * 处理流程：
 * 1、证书与私钥文件都在时直接加载
 * 2、否则生成 ECDSA P-256 私钥与十年有效期的自签名证书
 * 3、以 0600 权限写入磁盘
 * 4、计算证书 DER 的 SHA-256 指纹
 */
func LoadOrCreateIdentity(dir, hostName string) (*Identity, error) {
	certPath := filepath.Join(dir, "host.crt")
	keyPath := filepath.Join(dir, "host.key")
	// 1、已有证书
	if cert, err := tls.LoadX509KeyPair(certPath, keyPath); err == nil {
		return &Identity{Cert: cert, Fingerprint: Fingerprint(cert.Certificate[0])}, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("加载证书失败: %w", err)
	}
	// 2、生成新证书
	certPEM, keyPEM, err := generate(hostName)
	if err != nil {
		return nil, err
	}
	// 3、落盘
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		return nil, fmt.Errorf("写入私钥失败: %w", err)
	}
	if err := os.WriteFile(certPath, certPEM, 0o600); err != nil {
		return nil, fmt.Errorf("写入证书失败: %w", err)
	}
	// 4、指纹
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, err
	}
	return &Identity{Cert: cert, Fingerprint: Fingerprint(cert.Certificate[0])}, nil
}

/** Fingerprint：证书 DER 的 SHA-256 十六进制小写 */
func Fingerprint(der []byte) string {
	sum := sha256.Sum256(der)
	return hex.EncodeToString(sum[:])
}

/** generate：生成 PEM 格式的自签名证书与私钥 */
func generate(hostName string) ([]byte, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		return nil, nil, err
	}
	tpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: hostName, Organization: []string{"PocketDesk"}},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"localhost", hostName},
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return nil, nil, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	return certPEM, keyPEM, nil
}
