// SPDX-FileCopyrightText: 2026 The Crossplane Authors <https://crossplane.io>
//
// SPDX-License-Identifier: Apache-2.0

package pool

import (
	"database/sql"
	"testing"
)

// A ProviderConfig edit reaches Get as a different cfg for the same DSN. The
// database/sql setters are safe on a live pool, so the change must apply.
func TestGetAppliesChangedConfig(t *testing.T) {
	resetCache(t)
	openDB = func(_, _ string, cfg Config) (*sql.DB, error) {
		db := newFakeDB()
		cfg.apply(db)
		return db, nil
	}

	first := Config{MaxOpenConns: 7, MaxIdleConns: 2}
	if _, err := Get("mysql", "dsn-1", first); err != nil {
		t.Fatalf("Get: %v", err)
	}

	changed := Config{MaxOpenConns: 3, MaxIdleConns: 1}
	db, err := Get("mysql", "dsn-1", changed)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got := db.Stats().MaxOpenConnections; got != changed.MaxOpenConns {
		t.Errorf("MaxOpenConnections after config change = %d, want %d", got, changed.MaxOpenConns)
	}
}
