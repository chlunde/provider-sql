// SPDX-FileCopyrightText: 2026 The Crossplane Authors <https://crossplane.io>
//
// SPDX-License-Identifier: Apache-2.0

package pool

// Cached reports whether a pool for driver and dsn is currently held by the
// cache. It exists so client packages can assert they go through Get.
func Cached(driver, dsn string) bool {
	mu.Lock()
	defer mu.Unlock()
	_, ok := cache[driver+"\x00"+dsn]
	return ok
}
