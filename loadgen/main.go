package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func mustInterval() time.Duration {
	ms, err := strconv.Atoi(env("INTERVAL_MS", "2000"))
	if err != nil || ms < 100 {
		ms = 2000
	}
	return time.Duration(ms) * time.Millisecond
}

func dsn() string {
	if u := os.Getenv("DATABASE_URL"); u != "" {
		return u
	}
	return fmt.Sprintf(
		"postgres://%s:%s@%s:%s/%s?sslmode=%s",
		env("PGUSER", "app"),
		env("PGPASSWORD", ""),
		env("PGHOST", "pg-cluster-rw"),
		env("PGPORT", "5432"),
		env("PGDATABASE", "app"),
		env("PGSSLMODE", "require"),
	)
}

func ensureSchema(ctx context.Context, pool *pgxpool.Pool) error {
	_, err := pool.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS loadgen_heartbeat (
			id BIGSERIAL PRIMARY KEY,
			note TEXT NOT NULL,
			created_at TIMESTAMPTZ NOT NULL DEFAULT now()
		)`)
	return err
}

func writeOnce(ctx context.Context, pool *pgxpool.Pool) error {
	_, err := pool.Exec(ctx,
		`INSERT INTO loadgen_heartbeat (note) VALUES ($1)`,
		fmt.Sprintf("write-%d", time.Now().UnixNano()))
	return err
}

func readOnce(ctx context.Context, pool *pgxpool.Pool) (int64, error) {
	var n int64
	err := pool.QueryRow(ctx, `SELECT COUNT(*) FROM loadgen_heartbeat`).Scan(&n)
	return n, err
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("loadgen ")

	interval := mustInterval()
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	cfg, err := pgxpool.ParseConfig(dsn())
	if err != nil {
		log.Fatalf("parse dsn: %v", err)
	}
	cfg.MaxConns = 4

	var pool *pgxpool.Pool
	for attempt := 1; attempt <= 60; attempt++ {
		pool, err = pgxpool.NewWithConfig(ctx, cfg)
		if err == nil {
			if pingErr := pool.Ping(ctx); pingErr == nil {
				break
			} else {
				err = pingErr
				pool.Close()
			}
		}
		log.Printf("waiting for postgres (attempt %d/60): %v", attempt, err)
		select {
		case <-ctx.Done():
			log.Fatal("canceled while waiting for postgres")
		case <-time.After(2 * time.Second):
		}
	}
	if err != nil {
		log.Fatalf("postgres unavailable: %v", err)
	}
	defer pool.Close()

	if err := ensureSchema(ctx, pool); err != nil {
		log.Fatalf("schema: %v", err)
	}
	log.Printf("connected; interval=%s host=%s", interval, env("PGHOST", "pg-cluster-rw"))

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	go func() {
		addr := env("HTTP_ADDR", ":8080")
		log.Printf("health listening on %s", addr)
		if err := http.ListenAndServe(addr, mux); err != nil {
			log.Printf("http: %v", err)
		}
	}()

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	var writesOK, writesErr, readsOK, readsErr int64
	for {
		select {
		case <-ctx.Done():
			log.Printf("shutdown writes_ok=%d writes_err=%d reads_ok=%d reads_err=%d",
				writesOK, writesErr, readsOK, readsErr)
			return
		case <-ticker.C:
			wctx, wcancel := context.WithTimeout(ctx, 5*time.Second)
			if err := writeOnce(wctx, pool); err != nil {
				writesErr++
				log.Printf("WRITE fail: %v", err)
			} else {
				writesOK++
				log.Printf("WRITE ok (ok=%d err=%d)", writesOK, writesErr)
			}
			wcancel()

			rctx, rcancel := context.WithTimeout(ctx, 5*time.Second)
			n, err := readOnce(rctx, pool)
			if err != nil {
				readsErr++
				log.Printf("READ  fail: %v", err)
			} else {
				readsOK++
				log.Printf("READ  ok count=%d (ok=%d err=%d)", n, readsOK, readsErr)
			}
			rcancel()
		}
	}
}
