/**
 * 发件箱：监听电脑上的 Outbox 目录，登记待发文件；手机确认后移到 .sent/YYYYMMDD/。
 */
package outbox

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/ewkzcz/pocketdesk/server/internal/naming"
	"github.com/ewkzcz/pocketdesk/server/internal/security"
	"github.com/ewkzcz/pocketdesk/server/internal/store"
	"github.com/fsnotify/fsnotify"
	"golang.org/x/text/unicode/norm"
)

/** sentDir：已发送文件的归档子目录 */
const sentDir = ".sent"

/** Service：发件箱服务 */
type Service struct {
	store    *store.Store
	dir      string
	settle   time.Duration
	now      func() time.Time
	mu       sync.Mutex
	timers   map[string]*time.Timer
	OnNew    func(store.OutboxItem)
	watcher  *fsnotify.Watcher
	stopOnce sync.Once
}

/** New：创建发件箱服务 */
func New(s *store.Store, dir string) (*Service, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	return &Service{store: s, dir: dir, settle: time.Second, now: time.Now, timers: map[string]*time.Timer{}}, nil
}

/** SetSettle：文件稳定判定时长，仅供测试缩短 */
func (s *Service) SetSettle(d time.Duration) { s.settle = d }

/** Dir：发件目录 */
func (s *Service) Dir() string { return s.dir }

/**
 * Start：扫描已有文件并开始监听
 *
 * 处理流程：
 * 1、登记目录中已存在的文件
 * 2、启动 fsnotify 监听，新文件稳定后登记
 */
func (s *Service) Start(ctx context.Context) error {
	// 1、初始扫描
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if s.eligible(e.Name()) && !e.IsDir() {
			if _, err := s.register(ctx, filepath.Join(s.dir, e.Name()), ""); err != nil {
				slog.Warn("登记发件失败", "err", err)
			}
		}
	}
	// 2、监听
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	if err := w.Add(s.dir); err != nil {
		w.Close()
		return err
	}
	s.watcher = w
	go s.loop(ctx, w)
	return nil
}

/** Stop：停止监听 */
func (s *Service) Stop() {
	s.stopOnce.Do(func() {
		if s.watcher != nil {
			s.watcher.Close()
		}
		s.mu.Lock()
		for _, t := range s.timers {
			t.Stop()
		}
		s.mu.Unlock()
	})
}

/** loop：处理文件事件，写入完成后延迟登记 */
func (s *Service) loop(ctx context.Context, w *fsnotify.Watcher) {
	for {
		select {
		case <-ctx.Done():
			s.Stop()
			return
		case ev, ok := <-w.Events:
			if !ok {
				return
			}
			name := filepath.Base(ev.Name)
			if !s.eligible(name) {
				continue
			}
			if ev.Op&(fsnotify.Remove|fsnotify.Rename) != 0 {
				// 与 Ack 共用锁，避免确认移动时误删刚标记的记录
				s.mu.Lock()
				s.store.DeleteOutboxByPath(ctx, ev.Name)
				s.mu.Unlock()
				continue
			}
			if ev.Op&(fsnotify.Create|fsnotify.Write) != 0 {
				s.schedule(ctx, ev.Name)
			}
		case err, ok := <-w.Errors:
			if !ok {
				return
			}
			slog.Warn("发件目录监听出错", "err", err)
		}
	}
}

/** schedule：同一文件的连续写入只在最后一次之后登记 */
func (s *Service) schedule(ctx context.Context, p string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if t, ok := s.timers[p]; ok {
		t.Stop()
	}
	s.timers[p] = time.AfterFunc(s.settle, func() {
		s.mu.Lock()
		delete(s.timers, p)
		s.mu.Unlock()
		info, err := os.Stat(p)
		if err != nil || info.IsDir() {
			return
		}
		if _, err := s.store.OutboxByPath(ctx, p); err == nil {
			return
		}
		if _, err := s.register(ctx, p, ""); err != nil {
			slog.Warn("登记发件失败", "err", err)
		}
	})
}

/** eligible：忽略隐藏文件和临时文件 */
func (s *Service) eligible(name string) bool {
	return !strings.HasPrefix(name, ".") && !strings.HasSuffix(name, "~") && !strings.HasSuffix(name, ".tmp")
}

/**
 * register：计算哈希并登记
 *
 * 处理流程：
 * 1、读取大小并计算 SHA-256
 * 2、写入发件表并回调通知
 */
func (s *Service) register(ctx context.Context, p, target string) (store.OutboxItem, error) {
	// 1、哈希
	info, err := os.Stat(p)
	if err != nil {
		return store.OutboxItem{}, err
	}
	sum, err := hashFile(p)
	if err != nil {
		return store.OutboxItem{}, err
	}
	// 2、登记
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

/**
 * Send：把电脑上的文件复制进发件箱并登记（供命令行和右键菜单使用）
 *
 * 处理流程：
 * 1、复制到发件箱内的隐藏临时文件，监听会忽略它
 * 2、按命名规则落到发件箱，重名加序号
 * 3、登记并指定目标设备
 */
func (s *Service) Send(ctx context.Context, src, target string) (store.OutboxItem, error) {
	// 1、临时复制
	info, err := os.Stat(src)
	if err != nil {
		return store.OutboxItem{}, err
	}
	if info.IsDir() {
		return store.OutboxItem{}, errors.New("暂不支持发送文件夹")
	}
	tmp, err := os.CreateTemp(s.dir, ".pd-send-*")
	if err != nil {
		return store.OutboxItem{}, err
	}
	in, err := os.Open(src)
	if err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return store.OutboxItem{}, err
	}
	_, err = io.Copy(tmp, in)
	in.Close()
	tmp.Close()
	if err != nil {
		os.Remove(tmp.Name())
		return store.OutboxItem{}, err
	}
	// 2、落盘到发件箱；持锁登记，避免监听抢先以无目标方式登记
	s.mu.Lock()
	name, err := naming.Place(tmp.Name(), s.dir, filepath.Base(src))
	if err != nil {
		s.mu.Unlock()
		os.Remove(tmp.Name())
		return store.OutboxItem{}, err
	}
	// 3、登记
	it, err := s.register(ctx, filepath.Join(s.dir, name), target)
	s.mu.Unlock()
	return it, err
}

/**
 * Ack：手机确认收到，移到 .sent/YYYYMMDD/
 *
 * 处理流程：
 * 1、查询待发记录
 * 2、移动到归档目录，重名加序号
 * 3、标记为已发送
 */
func (s *Service) Ack(ctx context.Context, id string) error {
	// 1、查询
	it, err := s.store.OutboxItem(ctx, id)
	if err != nil {
		return err
	}
	if it.Status != store.OutboxPending {
		return nil
	}
	// 2、移动（持锁，保证移动与标记之间不被删除事件打断）
	s.mu.Lock()
	defer s.mu.Unlock()
	dir := filepath.Join(s.dir, sentDir, naming.DateFolder(s.now()))
	newPath := it.Path
	if _, err := os.Stat(it.Path); err == nil {
		name, err := naming.Place(it.Path, dir, it.Name)
		if err != nil {
			return err
		}
		newPath = filepath.Join(dir, name)
	}
	// 3、标记
	return s.store.MarkOutboxSent(ctx, id, newPath)
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
