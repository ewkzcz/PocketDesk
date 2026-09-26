/**
 * 随机令牌、ID 与哈希工具。
 */
package security

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
)

/** NewToken：32 字节随机数的 URL 安全编码，用作设备长期令牌 */
func NewToken() string {
	return randomString(32)
}

/** NewID：16 字节随机数的十六进制，用作记录主键 */
func NewID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

/** HashToken：令牌只以哈希形式入库 */
func HashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

/** EqualConstant：常量时间比较，防止时序侧信道 */
func EqualConstant(a, b string) bool {
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

/** randomString：n 字节随机数的无填充 base64url */
func randomString(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
