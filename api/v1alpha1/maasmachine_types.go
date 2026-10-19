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
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// MAASMachine is the operator's self-contained contract for a single physical
// machine provisioned via Canonical MAAS. It is intentionally "fat": all data
// needed to enlist, commission, configure, and deploy a node is carried inline
// (deduplicated at authoring time via Helm), rather than referencing separate
// profile CRDs at runtime. It replaces the Drydock BaremetalNode document
// (drydock/BaremetalNode/v1), which spreads this data across separate
// host and hardware profile documents.
//
// Fields that MAAS discovers (vendor, BIOS, kernel-assigned device names) live
// in status, not spec. The fabrics, VLANs and subnets referenced by the
// network configuration are ensured in MAAS on demand: created when missing and
// updated when they differ. DHCP and IP ranges are not managed.

// ---------------------------------------------------------------------------
// Placement
// ---------------------------------------------------------------------------

// Placement selects where in MAAS the machine is organized.
type Placement struct {
	// Zone is the MAAS zone to place the machine in.
	// +optional
	Zone string `json:"zone,omitempty"`

	// ResourcePool is the MAAS resource pool for the machine.
	// +optional
	ResourcePool string `json:"resourcePool,omitempty"`

	// Tags are MAAS tags to ensure are applied to the machine.
	// +optional
	Tags []string `json:"tags,omitempty"`
}

// ---------------------------------------------------------------------------
// Hardware: manifest-stable, bus-address addressing
// ---------------------------------------------------------------------------

// BusType describes how a DeviceAlias.Address is interpreted.
// +kubebuilder:validation:Enum=pci;scsi;idrac;usb;virtio
type BusType string

// DeviceAlias maps a manifest-stable, human-authored name (e.g. "pxe_nic01",
// "bootdisk") to a physical device by its bus address. This is the SKU-stable
// addressing layer MAAS does not provide from discovery (MAAS reports ephemeral
// kernel names + per-unit serials). Interfaces and disks reference these aliases
// and the operator resolves each alias to the MAAS-discovered device by matching
// its bus address.
type DeviceAlias struct {
	// Name is the stable alias referenced by interfaces and storage.
	Name string `json:"name"`

	// Address is the bus address, e.g. PCI "0000:06:00.0" or SCSI "0:2.0.0".
	Address string `json:"address"`

	// Bus is how Address is interpreted.
	// +optional
	Bus BusType `json:"bus,omitempty"`

	// Dev is an informational device class ("disk" or "nic"); it is not validated.
	// +optional
	Dev string `json:"dev,omitempty"`
}

// ---------------------------------------------------------------------------
// Networking
// ---------------------------------------------------------------------------

// Route is a static route programmed on the deployed node.
type Route struct {
	// Destination is the target CIDR; "0.0.0.0/0" expresses a default route.
	Destination string `json:"destination"`

	// Gateway is the next-hop address.
	Gateway string `json:"gateway"`

	// Metric optionally sets the route metric.
	// +optional
	Metric *int `json:"metric,omitempty"`
}

// SRIOVConfig requests SR-IOV virtual functions on a physical interface.
type SRIOVConfig struct {
	// VFCount is the number of virtual functions to enable.
	// +kubebuilder:validation:Minimum=0
	VFCount int `json:"vfCount"`

	// TrustMode enables trusted mode on the created virtual functions.
	// +optional
	TrustMode bool `json:"trustMode,omitempty"`
}

// DeviceMatch selects physical interfaces using a stable bus alias or MAC address.
type DeviceMatch struct {
	// DeviceAlias resolves this interface to a physical NIC by bus address.
	// +optional
	DeviceAlias string `json:"deviceAlias,omitempty"`

	// MACAddress selects physical NIC by MAC.
	// +optional
	MACAddress string `json:"macAddress,omitempty"`
}

// InterfaceCommon holds the layer-3 settings shared by ethernet, bond and VLAN
// interfaces. It is inlined, so these fields appear directly on each interface.
type InterfaceCommon struct {
	// Network is the logical network alias (e.g. "pxe", "oam", "storage").
	// +optional
	Network string `json:"network,omitempty"`

	// MTU overrides the interface MTU.
	// +optional
	MTU *int `json:"mtu,omitempty"`

	// Addresses is the list of IPv4 or IPv6 addresses with prefix length (e.g. "172.30.1.13/25").
	// +optional
	Addresses []string `json:"addresses,omitempty"`

	// Gateway4 sets the default IPv4 gateway for this interface.
	// +optional
	Gateway4 string `json:"gateway4,omitempty"`

	// Routes are additional static routes attached to this interface.
	// +optional
	Routes []Route `json:"routes,omitempty"`

	// LinkMode is the link state/mode (e.g. "link-up", "unconfigured").
	// +optional
	LinkMode string `json:"linkMode,omitempty"`

	// DNS configures resolver settings specific to this interface or its subnet.
	// +optional
	DNS *DNSConfig `json:"dns,omitempty"`
}

// EthernetConfig represents a physical ethernet interface definition.
type EthernetConfig struct {
	InterfaceCommon `json:",inline"`

	// Match selects the physical device.
	// +optional
	Match *DeviceMatch `json:"match,omitempty"`

	// SRIOV requests virtual functions on a physical interface.
	// +optional
	SRIOV *SRIOVConfig `json:"sriov,omitempty"`
}

// BondMemberAttachment selects a member of a bond interface.
type BondMemberAttachment struct {
	// Match selects the physical interface.
	Match DeviceMatch `json:"match"`
}

// BondParameters holds bonding mode and timing parameters.
type BondParameters struct {
	// Mode is the bonding mode (e.g. "802.3ad", "active-backup", "balance-rr").
	// +kubebuilder:validation:Enum=balance-rr;active-backup;balance-xor;broadcast;"802.3ad";balance-tlb;balance-alb
	// +kubebuilder:default="802.3ad"
	Mode string `json:"mode"`

	// LACPRate is the 802.3ad LACPDU transmit rate.
	// +kubebuilder:validation:Enum=slow;fast
	// +optional
	LACPRate string `json:"lacpRate,omitempty"`

	// TransmitHashPolicy is the transmit hash policy for balancing modes.
	// +kubebuilder:validation:Enum=layer2;layer2+3;layer3+4;encap2+3;encap3+4
	// +optional
	TransmitHashPolicy string `json:"transmitHashPolicy,omitempty"`

	// MIIMonitorInterval is the MII link monitoring interval in milliseconds.
	// +optional
	MIIMonitorInterval *int `json:"miiMonitorInterval,omitempty"`

	// UpDelay is the delay before enabling a link after it comes up, in milliseconds.
	// +optional
	UpDelay *int `json:"upDelay,omitempty"`

	// DownDelay is the delay before disabling a link after it goes down, in milliseconds.
	// +optional
	DownDelay *int `json:"downDelay,omitempty"`
}

// BondConfig represents a bonded link-aggregation group.
type BondConfig struct {
	InterfaceCommon `json:",inline"`

	// Interfaces lists the member physical interfaces of this bond.
	Interfaces []BondMemberAttachment `json:"interfaces"`

	// Parameters holds bonding mode and timing parameters.
	// +optional
	Parameters *BondParameters `json:"parameters,omitempty"`
}

// VLANConfig represents an 802.1Q tagged virtual interface.
type VLANConfig struct {
	InterfaceCommon `json:",inline"`

	// ID is the IEEE 802.1Q VLAN ID (0 for untagged).
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:validation:Maximum=4094
	ID int `json:"id"`

	// Link is the parent interface name within the fabric (e.g. "bond1" or "pxe").
	Link string `json:"link"`
}

// FabricNetplanConfig models Netplan v2 interface categories scoped to a specific MAAS fabric.
type FabricNetplanConfig struct {
	// Ethernets defines physical interfaces connected to this fabric.
	// +optional
	Ethernets map[string]EthernetConfig `json:"ethernets,omitempty"`

	// Bonds defines link aggregation groups connected to this fabric.
	// +optional
	Bonds map[string]BondConfig `json:"bonds,omitempty"`

	// VLANs defines 802.1Q tagged virtual interfaces in this fabric.
	// +optional
	VLANs map[string]VLANConfig `json:"vlans,omitempty"`
}

// DNSConfig holds host-level resolver configuration.
type DNSConfig struct {
	// Nameservers lists upstream DNS servers configured on the node.
	// +optional
	Nameservers []string `json:"nameservers,omitempty"`

	// Search lists DNS search domains configured on the node.
	// +optional
	Search []string `json:"search,omitempty"`
}

// NetworkConfig is the machine-level networking layout.
type NetworkConfig struct {
	// PrimaryNetwork is the primary logical network name (e.g. "oam").
	// +optional
	PrimaryNetwork string `json:"primaryNetwork,omitempty"`

	// DNS defines host-wide DNS nameservers and search paths.
	// +optional
	DNS *DNSConfig `json:"dns,omitempty"`

	// Fabrics maps each L2 Fabric name to its Netplan-idiomatic interface layout.
	// +optional
	Fabrics map[string]FabricNetplanConfig `json:"fabrics,omitempty"`
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

// StorageLayout is a MAAS quick storage preset.
// +kubebuilder:validation:Enum=flat;lvm;bcache;vmfs6;blank
type StorageLayout string

// Filesystem describes a filesystem placed on a partition or logical volume.
type Filesystem struct {
	// Type is the filesystem type.
	// +kubebuilder:validation:Enum=ext4;xfs;btrfs;vfat;fat32;swap
	Type string `json:"type"`

	// MountPoint is the absolute mount path; omit for swap or unmounted volumes.
	// +optional
	MountPoint string `json:"mountPoint,omitempty"`

	// MountOptions are extra mount options (fstab field).
	// +optional
	MountOptions string `json:"mountOptions,omitempty"`

	// Label is the filesystem label.
	// +optional
	Label string `json:"label,omitempty"`
}

// Partition is a partition carved from a Disk.
type Partition struct {
	// Name is a stable handle for the partition (map key), e.g. "root", "pv0".
	Name string `json:"name"`

	// Number optionally pins the partition number/order.
	// +optional
	Number *int `json:"number,omitempty"`

	// SizeGiB is the partition size in GiB; omit with Grow=true to consume the
	// remaining free space on the disk.
	// +optional
	SizeGiB *int64 `json:"sizeGiB,omitempty"`

	// Grow expands the partition to fill the remaining free space.
	// +optional
	Grow bool `json:"grow,omitempty"`

	// Bootable marks the partition bootable.
	// +optional
	Bootable bool `json:"bootable,omitempty"`

	// Labels are free-form key/value labels used to identify the partition.
	// +optional
	Labels map[string]string `json:"labels,omitempty"`

	// Filesystem places a filesystem directly on the partition. Omit when the
	// partition is used as an LVM physical volume.
	// +optional
	Filesystem *Filesystem `json:"filesystem,omitempty"`
}

// Disk is an explicitly partitioned block device.
type Disk struct {
	// DeviceAlias (preferred) selects the block device by bus address.
	// +optional
	DeviceAlias string `json:"deviceAlias,omitempty"`

	// Name selects the block device by MAAS/kernel name when no alias is used.
	// +optional
	Name string `json:"name,omitempty"`

	// Bootable marks this disk as the boot device.
	// +optional
	Bootable bool `json:"bootable,omitempty"`

	// PartitionTable is the partition table type.
	// +kubebuilder:validation:Enum=gpt;mbr
	// +optional
	PartitionTable string `json:"partitionTable,omitempty"`

	// Labels are free-form key/value labels used to identify the disk.
	// +optional
	Labels map[string]string `json:"labels,omitempty"`

	// Partitions is the ordered set of partitions on the disk.
	// +optional
	// +listType=map
	// +listMapKey=name
	Partitions []Partition `json:"partitions,omitempty"`
}

// LogicalVolume is an LVM logical volume within a VolumeGroup.
type LogicalVolume struct {
	// Name is the logical volume name.
	Name string `json:"name"`

	// SizeGiB is the volume size in GiB; omit with Grow=true to consume the
	// remaining free extents in the volume group.
	// +optional
	SizeGiB *int64 `json:"sizeGiB,omitempty"`

	// Grow expands the volume to fill the remaining free extents.
	// +optional
	Grow bool `json:"grow,omitempty"`

	// Filesystem places a filesystem on the logical volume.
	// +optional
	Filesystem *Filesystem `json:"filesystem,omitempty"`
}

// VolumeGroup is an LVM volume group built from disks/partitions used as PVs.
type VolumeGroup struct {
	// Name is the volume group name.
	Name string `json:"name"`

	// Members reference physical volumes: a whole disk ("bootdisk") or a
	// partition ("bootdisk:pv0").
	Members []string `json:"members"`

	// LogicalVolumes are the volumes carved from this group.
	// +optional
	// +listType=map
	// +listMapKey=name
	LogicalVolumes []LogicalVolume `json:"logicalVolumes,omitempty"`
}

// StorageSpec is the desired storage layout for the machine.
type StorageSpec struct {
	// Layout is the MAAS quick preset applied when Disks is empty.
	// +kubebuilder:default=flat
	// +optional
	Layout StorageLayout `json:"layout,omitempty"`

	// BootDeviceAlias pins the boot disk when using a Layout preset.
	// +optional
	BootDeviceAlias string `json:"bootDeviceAlias,omitempty"`

	// Disks defines explicit partitioning; overrides Layout when set.
	// +optional
	Disks []Disk `json:"disks,omitempty"`

	// VolumeGroups defines LVM on top of disks/partitions used as PVs.
	// +optional
	// +listType=map
	// +listMapKey=name
	VolumeGroups []VolumeGroup `json:"volumeGroups,omitempty"`
}

// ---------------------------------------------------------------------------
// Platform tuning
// ---------------------------------------------------------------------------

// BootMode selects the firmware boot mode.
// +kubebuilder:validation:Enum=bios;uefi
type BootMode string

// ProvisioningMethod selects how a machine is bootstrapped into the MAAS
// enlist -> commission -> deploy lifecycle.
// +kubebuilder:validation:Enum=Auto;Network;VirtualMedia
type ProvisioningMethod string

const (
	// ProvisioningAuto lets the operator choose Network or VirtualMedia from the
	// machine's BMC capabilities and whether it is co-located with a MAAS rack
	// controller that serves DHCP (matched by DNS domain, since boot CIDRs are
	// reused across sites).
	ProvisioningAuto ProvisioningMethod = "Auto"
	// ProvisioningNetwork uses traditional MAAS-managed PXE (DHCP + TFTP/iPXE) on
	// the node's boot L2 segment. No per-node ISO or boot proxy is involved. When
	// the node is not yet in MAAS, the operator drives its BMC to set a one-time
	// PXE boot and power-cycles it so MAAS discovers and self-enlists it; MAAS
	// then owns power/boot for the remaining commission/deploy lifecycle.
	ProvisioningNetwork ProvisioningMethod = "Network"
	// ProvisioningVirtualMedia boots a per-node iPXE ISO via the BMC's virtual
	// media (e.g. Redfish InsertVirtualMedia). Used for nodes with no MAAS-managed
	// DHCP/PXE on their boot segment; the static boot config is baked into the ISO
	// and all MAAS traffic flows through the maas-boot-proxy. The BMC must be
	// virtual-media-capable (e.g. powerType: redfish).
	ProvisioningVirtualMedia ProvisioningMethod = "VirtualMedia"
)

// ProvisioningSpec selects and tunes how the machine reaches the MAAS lifecycle.
type ProvisioningSpec struct {
	// Method selects the bootstrap mechanism. The default, Auto, picks Network
	// or VirtualMedia automatically; set one explicitly to override that choice.
	// +kubebuilder:default=Auto
	// +optional
	Method ProvisioningMethod `json:"method,omitempty"`
}

// HugePages requests a hugepage allocation on the node.
type HugePages struct {
	// Name is a stable label for the allocation (map key), often a NUMA group.
	Name string `json:"name"`

	// Size is the hugepage size, e.g. "2M" or "1G".
	Size string `json:"size"`

	// Count is the number of pages of this size to allocate.
	Count int64 `json:"count"`
}

// PackageRepo is an apt/rpm repository configured on the node.
type PackageRepo struct {
	// Name is a stable identifier for the repository (map key).
	Name string `json:"name"`

	// Type is the repository class.
	// +kubebuilder:validation:Enum=apt;rpm
	Type string `json:"type"`

	// URL is the repository base URL.
	URL string `json:"url"`

	// Distributions are the apt distributions/suites to enable.
	// +optional
	Distributions []string `json:"distributions,omitempty"`

	// Components are the apt components to enable.
	// +optional
	Components []string `json:"components,omitempty"`

	// GPGKey is the armored signing key or a key URL.
	// +optional
	GPGKey string `json:"gpgKey,omitempty"`

	// Arches restricts the repository to the listed architectures.
	// +optional
	Arches []string `json:"arches,omitempty"`
}

// ---------------------------------------------------------------------------
// Spec
// ---------------------------------------------------------------------------

// MAASMachineSpec defines the desired state of a MAASMachine.
type MAASMachineSpec struct {
	// DesiredState is the MAAS lifecycle state to drive the machine toward.
	// +kubebuilder:default=Deployed
	// +optional
	DesiredState DesiredState `json:"desiredState,omitempty"`

	// Identity is how the operator matches or names the machine in MAAS.
	// +optional
	Identity Identity `json:"identity,omitempty"`

	// BMC holds out-of-band power credentials used to enlist the machine when
	// it is not already present in MAAS.
	// +optional
	BMC *BMC `json:"bmc,omitempty"`

	// Placement organizes the machine within MAAS (zone, pool, tags).
	// +optional
	Placement Placement `json:"placement,omitempty"`

	// Resources constrains machine allocation to a minimum compute footprint.
	// +optional
	Resources *ResourceConstraints `json:"resources,omitempty"`

	// OS is the operating system to deploy when DesiredState is Deployed.
	// +optional
	OS OS `json:"os,omitempty"`

	// BootMode selects the firmware boot mode (bios/uefi).
	// +optional
	BootMode BootMode `json:"bootMode,omitempty"`

	// Provisioning selects how the machine is bootstrapped into the MAAS
	// lifecycle.
	// +optional
	Provisioning ProvisioningSpec `json:"provisioning,omitempty"`

	// KernelParams are appended to the deployed node's kernel command line
	// (e.g. isolcpus, intel_iommu, hugepagesz).
	// +optional
	KernelParams map[string]string `json:"kernelParams,omitempty"`

	// HugePages requests hugepage allocations on the node.
	// +optional
	// +listType=map
	// +listMapKey=name
	HugePages []HugePages `json:"hugePages,omitempty"`

	// CPUSets maps a name to an isolated CPU list, e.g. "dpdk": "2-9,14-21".
	// +optional
	CPUSets map[string]string `json:"cpuSets,omitempty"`

	// DeviceAliases maps manifest-stable names to bus addresses. Interfaces and
	// storage reference these aliases.
	// +optional
	// +listType=map
	// +listMapKey=name
	DeviceAliases []DeviceAlias `json:"deviceAliases,omitempty"`

	// Network is the machine-level networking layout.
	// +optional
	Network *NetworkConfig `json:"network,omitempty"`

	// Storage is the desired storage layout.
	// +optional
	Storage *StorageSpec `json:"storage,omitempty"`

	// OwnerData is arbitrary key/value data stored on the MAAS machine object.
	// +optional
	OwnerData map[string]string `json:"ownerData,omitempty"`

	// SSHAuthorizedKeys are public keys authorized on the deployed node.
	// +optional
	SSHAuthorizedKeys []string `json:"sshAuthorizedKeys,omitempty"`

	// PackageRepositories are apt/rpm sources configured on the node.
	// +optional
	// +listType=map
	// +listMapKey=name
	PackageRepositories []PackageRepo `json:"packageRepositories,omitempty"`

	// UserDataSecretRef references a Secret key containing raw cloud-init
	// user-data applied at deploy time.
	// +optional
	UserDataSecretRef *corev1.SecretKeySelector `json:"userDataSecretRef,omitempty"`
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

// MachinePhase is a coarse, human-readable reconciliation phase.
// +kubebuilder:validation:Enum=Pending;Enlisting;Commissioning;Ready;Deploying;Deployed;Releasing;Released;Failed
type MachinePhase string

const (
	MachinePhasePending       MachinePhase = "Pending"
	MachinePhaseEnlisting     MachinePhase = "Enlisting"
	MachinePhaseCommissioning MachinePhase = "Commissioning"
	MachinePhaseReady         MachinePhase = "Ready"
	MachinePhaseDeploying     MachinePhase = "Deploying"
	MachinePhaseDeployed      MachinePhase = "Deployed"
	MachinePhaseReleasing     MachinePhase = "Releasing"
	MachinePhaseReleased      MachinePhase = "Released"
	MachinePhaseFailed        MachinePhase = "Failed"
)

// MAASMachineStatus defines the observed state of a MAASMachine.
type MAASMachineStatus struct {
	// Phase is a coarse, human-readable reconciliation phase.
	// +optional
	Phase MachinePhase `json:"phase,omitempty"`

	// SystemID is the MAAS system_id assigned to the machine, once known.
	// +optional
	SystemID string `json:"systemId,omitempty"`

	// ProviderID is a stable identifier of the form maas:///<zone>/<system_id>,
	// suitable for use as a Kubernetes node providerID.
	// +optional
	ProviderID string `json:"providerId,omitempty"`

	// PowerState is the last observed MAAS power state.
	// +optional
	PowerState string `json:"powerState,omitempty"`

	// Addresses are IP addresses currently reported by MAAS for the machine.
	// +optional
	Addresses []string `json:"addresses,omitempty"`

	// MACAddresses are the interface MAC addresses MAAS has registered for the
	// machine, seeded from spec.identity.macAddresses or the BMC-discovered NICs.
	// MAAS serves per-node boot config keyed by any of them (ipxe.cfg-<mac>).
	// +optional
	MACAddresses []string `json:"macAddresses,omitempty"`

	// ResolvedAliases echoes each spec DeviceAlias to the MAAS-discovered device
	// name it resolved to, so operators can audit bus-address mapping.
	// +optional
	ResolvedAliases map[string]string `json:"resolvedAliases,omitempty"`

	// ObservedGeneration is the .metadata.generation last reconciled.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`

	// ProvisioningMethod is the boot mechanism the operator resolved for this
	// machine (Network or VirtualMedia), after applying Auto inference.
	// +optional
	ProvisioningMethod ProvisioningMethod `json:"provisioningMethod,omitempty"`

	// ISOObjectKey is the object-store key of the per-node iPXE ISO currently
	// published for this machine, when ProvisioningMethod is VirtualMedia. It is
	// used to reclaim the artifact when the machine is deleted or re-imaged.
	// +optional
	ISOObjectKey string `json:"isoObjectKey,omitempty"`

	// Conditions represent the latest available observations of state.
	// +optional
	// +listType=map
	// +listMapKey=type
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:shortName=mm
// +kubebuilder:printcolumn:name="System ID",type=string,JSONPath=`.status.systemId`
// +kubebuilder:printcolumn:name="Desired",type=string,JSONPath=`.spec.desiredState`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Power",type=string,JSONPath=`.status.powerState`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// MAASMachine is the Schema for the maasmachines API. It represents a desired
// physical machine provisioned via Canonical MAAS.
type MAASMachine struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   MAASMachineSpec   `json:"spec,omitempty"`
	Status MAASMachineStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// MAASMachineList contains a list of MAASMachine.
type MAASMachineList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []MAASMachine `json:"items"`
}

func init() {
	SchemeBuilder.Register(&MAASMachine{}, &MAASMachineList{})
}
