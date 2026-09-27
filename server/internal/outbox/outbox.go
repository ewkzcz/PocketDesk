/**
 * 发往手机：电脑上的文件先复制到收件目录的日期文件夹（两端各留一份），登记为待发，手机收到后确认。
 */
package outbox

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/naming"
	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
	"golang.org/x/text/unicode/norm"
)

/** Service：发往手机的文件队列 */
type Service struct {
	store *store.Store
	dir   func() string
	now   func() time.Time
	OnNew func(store.OutboxItem)
}

/** New：创建队列，dir 返回当前收件目录 */
func New(s *store.Store, dir func() string) *Service {
	return &Service{store: s, dir: dir, now: time.Now}
}

/**
 * Send：把电脑上的文件发给手机
 *
 * 处理流程：
 * 1、复制到收件目录日期文件夹里的临时文件
 * 2、按命名规则落盘，重名加序号
 * 3、登记为待发并通知
 */
func (s *Service) Send(ctx context.Context, src, target string) (store.OutboxItem, error) {
	info, err := os.Stat(src)
	if err != nil {
		return store.OutboxItem{}, err
	}
	if info.IsDir() {
		return store.OutboxItem{}, errors.New("暂不支持发送文件夹")
	}
	in, err := os.Open(src)
	if err != nil {
		return store.OutboxItem{}, err
	}
	defer in.Close()
	return s.SendReader(ctx, in, filepath.Base(src), target)
}

/** SendReader：把一段内容以 name 为文件名发给手机（桌面端上传、粘贴的图片） */
func (s *Service) SendReader(ctx context.Context, r io.Reader, name, target string) (store.OutboxItem, error) {
	// 1、临时文件
	dir := filepath.Join(s.dir(), naming.DateFolder(s.now()))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return store.OutboxItem{}, err
	}
	tmp, err := os.CreateTemp(dir, ".pd-send-*")
	if err != nil {
		return store.OutboxItem{}, err
	}
	_, err = io.Copy(tmp, r)
	tmp.Close()
	if err != nil {
		os.Remove(tmp.Name())
		return store.OutboxItem{}, err
	}
	// 2、落盘
	final, err := naming.Place(tmp.Name(), dir, name)
	if err != nil {
		os.Remove(tmp.Name())
		return store.OutboxItem{}, err
	}
	// 3、登记
	return s.register(ctx, filepath.Join(dir, final), target)
}

/** register：计算大小与哈希后登记并通知 */
func (s *Service) register(ctx context.Context, p, target string) (store.OutboxItem, error) {
	info, err := os.Stat(p)
	if err != nil {
		return store.OutboxItem{}, err
	}
	sum, err := hashFile(p)
	if err != nil {
		return store.OutboxItem{}, err
	}
	it, err := s.store.UpsertOutbox(ctx, store.OutboxItem{
		ID: security.NewID(), Path: p, Name: norm.NFC.String(filepath.Base(p)), Size: info.Size(), SHA256: sum, TargetDevice: target,
	})
	if err != nil {
		return it, err
	}
	if s.OnNew != nil {
		s.OnNew(it)
	}
	return it, nil
}

/** Ack：手机确认收到，标记为已发送，文件留在原处 */
func (s *Service) Ack(ctx context.Context, id string) error {
	it, err := s.store.OutboxItem(ctx, id)
	if err != nil {
		return err
	}
	if it.Status != store.OutboxPending {
		return nil
	}
	return s.store.MarkOutboxSent(ctx, id, it.Path)
}

/** hashFile：文件 SHA-256 */
func hashFile(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
