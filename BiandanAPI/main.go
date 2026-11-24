// biandan-api：接收便单 Mac 版推送的日程快照，按分类以 JSON 提供给 ESP32 等设备查询。
//
// 用法：
//
//	biandan-api [serve]                 启动服务（读环境变量配置）
//	biandan-api genkey push|read|report <名称>  生成一把新密钥和要写进密钥文件的一行
//	biandan-api version                 显示版本
//
// 环境变量：
//
//	BIANDAN_API_LISTEN  监听地址，默认 127.0.0.1:18730（只给本机 nginx 转发）
//	BIANDAN_API_KEYS    密钥文件，默认 /etc/biandan-api/keys
//	BIANDAN_API_DATA    数据目录，默认 /var/lib/biandan-api（通用数据在其下的 datasets/）
//	BIANDAN_API_DATA_RETENTION_DAYS  通用数据保留天数，默认 400，0 表示不按时间清理
//	BIANDAN_API_DATA_TZ  通用数据默认时区，默认 Asia/Shanghai
package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
	_ "time/tzdata" // 服务器没装时区库也能换算 Asia/Shanghai
)

var buildVersion = "1.1.0"

const usage = `用法：
  biandan-api [serve]                 启动服务
  biandan-api genkey push|read|report <名称>  生成新密钥
  biandan-api version                 显示版本`

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func main() {
	log.SetFlags(log.LstdFlags)
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "genkey":
			os.Exit(genkey(os.Args[2:]))
		case "version", "--version", "-v":
			fmt.Println(buildVersion)
			return
		case "serve":
		default:
			fmt.Fprintln(os.Stderr, usage)
			os.Exit(2)
		}
	}

	listen := env("BIANDAN_API_LISTEN", "127.0.0.1:18730")
	keysPath := env("BIANDAN_API_KEYS", "/etc/biandan-api/keys")
	dataDir := env("BIANDAN_API_DATA", "/var/lib/biandan-api")

	srv, err := newServer(keysPath, dataDir)
	if err != nil {
		log.Fatalf("启动失败：%v", err)
	}
	httpServer := &http.Server{
		Addr:              listen,
		Handler:           srv,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}

	// systemctl reload 发 SIGHUP：重新读取密钥文件，不用重启。
	hup := make(chan os.Signal, 1)
	signal.Notify(hup, syscall.SIGHUP)
	go func() {
		for range hup {
			if err := srv.keys.reload(); err != nil {
				log.Printf("重新读取密钥失败，继续用原来的：%v", err)
			} else {
				log.Printf("已重新读取密钥：推送 %d 把，读取 %d 把，上报 %d 把", srv.keys.count("push"), srv.keys.count("read"), srv.keys.count("report"))
			}
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(ctx)
	}()

	log.Printf("biandan-api %s 监听 %s（推送密钥 %d 把，读取密钥 %d 把，上报密钥 %d 把，数据集 %d 个）", buildVersion, listen,
		srv.keys.count("push"), srv.keys.count("read"), srv.keys.count("report"), srv.data.count())
	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("监听失败：%v", err)
	}
}

func genkey(args []string) int {
	if len(args) != 2 || !keyRoles[args[0]] || !keyNamePattern.MatchString(args[1]) {
		fmt.Fprintln(os.Stderr, "用法：biandan-api genkey push|read|report <名称>（名称用字母、数字、点、下划线、短横线，最多 64 个）")
		return 2
	}
	token, err := newToken(args[0])
	if err != nil {
		fmt.Fprintln(os.Stderr, "生成随机数失败：", err)
		return 1
	}
	digest := hashKey(token)
	fmt.Printf("KEY %s\n", token)
	fmt.Printf("LINE %s %s sha256:%s\n", args[0], args[1], hex.EncodeToString(digest[:]))
	fmt.Fprintln(os.Stderr, "KEY 是密钥本身，只显示这一次；把 LINE 后面的内容加进密钥文件，再 systemctl reload biandan-api。")
	return 0
}

// newToken：推送密钥 bdp_ 开头，读取密钥 bdr_ 开头，上报密钥 bdu_ 开头，后面是 32 字节随机数的 base64url（43 个字符）。
func newToken(role string) (string, error) {
	prefix := "bdr_"
	switch role {
	case "push":
		prefix = "bdp_"
	case "report":
		prefix = "bdu_"
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return prefix + base64.RawURLEncoding.EncodeToString(raw), nil
}
