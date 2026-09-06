// SPDX-FileCopyrightText: 2026 The Crossplane Authors <https://crossplane.io>
//
// SPDX-License-Identifier: Apache-2.0

package mysql

import (
	"context"
	"testing"

	xpv2 "github.com/crossplane/crossplane/apis/v2/core/v2"
	// The client package does not register the driver itself; the provider
	// binary does. Register it here so sql.Open succeeds.
	_ "github.com/go-sql-driver/mysql"

	"github.com/crossplane-contrib/provider-sql/pkg/clients/pool"
	"github.com/crossplane-contrib/provider-sql/pkg/clients/xsql"
)

// Control for the postgresql test of the same name: mysql was converted.
func TestStatementsUsePool(t *testing.T) {
	ctx := context.Background()
	q := xsql.Query{String: "SELECT 1"}

	cases := map[string]func(db xsql.DB) error{
		"Exec": func(db xsql.DB) error { return db.Exec(ctx, q) },
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
	}

	for name, call := range cases {
		t.Run(name, func(t *testing.T) {
			// A distinct user per case gives each its own DSN.
			creds := map[string][]byte{
				xpv2.CredentialsSecretEndpointKey: []byte("127.0.0.1"),
				xpv2.CredentialsSecretPortKey:     []byte("1"),
				xpv2.CredentialsSecretUserKey:     []byte("u_" + name),
				xpv2.CredentialsSecretPasswordKey: []byte("p"),
			}
			db := New(creds, nil, nil, pool.Default)
			if err := call(db); err == nil {
				t.Fatalf("expected a connection error, got nil")
			}
			dsn := DSN("u_"+name, "p", "127.0.0.1", "1", "preferred", nil)
			if !pool.Cached(driverName, dsn) {
				t.Errorf("%s did not go through pool.Get", name)
			}
		})
	}
}
