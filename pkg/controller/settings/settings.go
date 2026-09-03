/*
Copyright 2026 The Crossplane Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Package settings holds provider-wide reconciler settings that
// crossplane-runtime's controller.Options has no field for.
package settings

import "time"

// CreationGracePeriod is how long after a successful Create a resource that
// Observe cannot find is still assumed to exist (eventual consistency).
// SQL engines are transactional, so a short value is safe; the default
// matches crossplane-runtime. Set from --creation-grace-period in main.
var CreationGracePeriod = 30 * time.Second
