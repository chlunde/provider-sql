// SPDX-FileCopyrightText: 2026 The Crossplane Authors <https://crossplane.io>
//
// SPDX-License-Identifier: Apache-2.0

package postgresql

import (
	"context"
	"testing"

	xpv2 "github.com/crossplane/crossplane/apis/v2/core/v2"

	"github.com/crossplane-contrib/provider-sql/pkg/clients/pool"
	"github.com/crossplane-contrib/provider-sql/pkg/clients/xsql"
)

// Every statement must go through the shared pool. sql.Open is lazy, so a
// DSN nobody listens on fails at connect time but still leaves a cached pool
// behind if, and only if, the client asked pool.Get for it.
func TestStatementsUsePool(t *testing.T) {
	ctx := context.Background()
	q := xsql.Query{String: "SELECT 1"}

	cases := map[string]func(db xsql.DB) error{
		"Exec":   func(db xsql.DB) error { return db.Exec(ctx, q) },
		"ExecTx": func(db xsql.DB) error { return db.ExecTx(ctx, []xsql.Query{q}) },
		"Query": func(db xsql.DB) error {
			rows, err := db.Query(ctx, q)
			if rows != nil {
				rows.Close() //nolint:errcheck
			}
			return err
		},
		"Scan": func(db xsql.DB) error {
			var n int
			return db.Scan(ctx, q, &n)
		},
		"GetServerVersion": func(db xsql.DB) error {
			_, err := db.GetServerVersion(ctx)
			return err
		},
	}

	for name, call := range cases {
		t.Run(name, func(t *testing.T) {
			// Port 1 on loopback: nothing listens, connect fails fast. A
			// distinct database name per case gives each its own DSN.
			creds := map[string][]byte{
				xpv2.CredentialsSecretEndpointKey: []byte("127.0.0.1"),
				xpv2.CredentialsSecretPortKey:     []byte("1"),
				xpv2.CredentialsSecretUserKey:     []byte("u"),
				xpv2.CredentialsSecretPasswordKey: []byte("p"),
			}
			db := New(creds, "db_"+name, "disable", pool.Default)
			if err := call(db); err == nil {
				t.Fatalf("expected a connection error, got nil")
			}
			dsn := DSN("u", "p", "127.0.0.1", "1", "db_"+name, "disable")
			if !pool.Cached(driverName, dsn) {
				t.Errorf("%s did not go through pool.Get: no cached pool for its DSN", name)
			}
		})
	}
}
