/*
Copyright 2026 The Airship Authors.

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

package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
)

// DesiredState represents the target lifecycle state a machine should reach in
// MAAS. The reconciler drives the machine through the MAAS lifecycle
// (enlist -> commission -> acquire -> deploy -> release) to satisfy it.
// +kubebuilder:validation:Enum=Commissioned;Ready;Deployed;Released
type DesiredState string

const (
	// StateCommissioned means the machine should be enlisted and commissioned.
	StateCommissioned DesiredState = "Commissioned"
	// StateReady means the machine should be commissioned and allocatable.
	StateReady DesiredState = "Ready"
	// StateDeployed means the machine should be deployed with the requested OS.
	StateDeployed DesiredState = "Deployed"
	// StateReleased means the machine should be released back to the pool.
	StateReleased DesiredState = "Released"
)

// Identity describes how to match an existing machine in MAAS. If no match is
// found and BMC power credentials are provided, the operator will enlist a new
// machine.
type Identity struct {
	// SystemID is the MAAS system_id of an already-enrolled machine.
	// +optional
	SystemID string `json:"systemId,omitempty"`

	// MACAddresses are boot interface MAC addresses used to match or enlist a
	// machine.
	// +optional
	MACAddresses []string `json:"macAddresses,omitempty"`

	// Hostname is the desired MAAS hostname for the machine. It may be an FQDN,
	// in which case the domain part is applied as the MAAS domain.
	// +optional
	Hostname string `json:"hostname,omitempty"`

	// Architecture is the MAAS architecture string (e.g. "amd64/generic") used
	// when pre-creating the machine via the MAAS API. Defaults to
	// "amd64/generic" when empty.
	// +optional
	Architecture string `json:"architecture,omitempty"`
}

// BMC holds out-of-band power management (IPMI/Redfish/etc.) details used to
// enlist and power-control a machine that is not yet known to MAAS.
type BMC struct {
	// PowerType is the MAAS power driver (e.g. "ipmi", "redfish", "amt").
	// +optional
	PowerType string `json:"powerType,omitempty"`

	// Address is the BMC address/host.
	// +optional
	Address string `json:"address,omitempty"`

	// Username is the BMC username.
	// +optional
	Username string `json:"username,omitempty"`

	// Password is the BMC password provided inline. It overrides
	// PasswordSecretRef; prefer the Secret reference.
	// +optional
	Password string `json:"password,omitempty"`

	// PasswordSecretRef references a Secret key holding the BMC password.
	// +optional
	PasswordSecretRef *corev1.SecretKeySelector `json:"passwordSecretRef,omitempty"`

	// Parameters carries additional power driver parameters passed to MAAS as is.
	// For redfish, "redfish_system_id" (or "node_id") selects the target system.
	// +optional
	Parameters map[string]string `json:"parameters,omitempty"`
}

// OS describes the operating system image to deploy.
type OS struct {
	// Distro is the OS distribution (e.g. "ubuntu").
	// +optional
	Distro string `json:"distro,omitempty"`

	// Release is the OS release/series (e.g. "noble").
	// +optional
	Release string `json:"release,omitempty"`

	// Kernel is an optional HWE/kernel selector (e.g. "ga-24.04").
	// +optional
	Kernel string `json:"kernel,omitempty"`
}

// ResourceConstraints expresses minimum compute requirements applied when
// allocating a machine from the MAAS ready pool. Zero-valued fields impose no
// constraint.
type ResourceConstraints struct {
	// MinCPU is the minimum number of CPU cores the allocated machine must have.
	// +optional
	// +kubebuilder:validation:Minimum=0
	MinCPU int `json:"minCPU,omitempty"`

	// MinMemoryMB is the minimum amount of RAM, in megabytes, the allocated
	// machine must have.
	// +optional
	// +kubebuilder:validation:Minimum=0
	MinMemoryMB int64 `json:"minMemoryMB,omitempty"`

	// MinDiskGB is the minimum size, in gigabytes, of at least one disk on the
	// allocated machine.
	// +optional
	// +kubebuilder:validation:Minimum=0
	MinDiskGB int `json:"minDiskGB,omitempty"`
}
