# Watcher Operator Controllers

This document provides a comprehensive overview of the controllers in the watcher-operator project, which manages the OpenStack Watcher service on Kubernetes/OpenShift platforms.

## Overview

The watcher-operator implements a Kubernetes operator using the **Kubebuilder v3** framework. It consists of **4 main controllers** that work together to orchestrate the complete Watcher service deployment with a hierarchical parent-child Custom Resource relationship pattern.

### Architecture Pattern

```
Watcher (Parent Controller)
├── WatcherAPI (Child)
├── WatcherDecisionEngine (Child)
└── WatcherApplier (Child)
```

- **API Group**: `watcher.openstack.org`
- **API Version**: `v1beta1`
- **Language**: Go 1.22.0+

## Controllers

### 1. Watcher Controller (Main Orchestrator)

**File**: `controllers/watcher_controller.go`

**Custom Resource**: `Watcher`

#### Purpose

The Watcher controller acts as the primary orchestrator, managing the complete Watcher service deployment by coordinating all infrastructure components and sub-services.

#### Main Responsibilities

1. **Infrastructure Setup**
   - Creates MariaDB database and account for persistent storage
   - Sets up RabbitMQ transport URLs (RPC and optional notification buses)
   - Configures Keystone service registration
   - Creates service account with RBAC (Role, RoleBinding)
   - Manages Prometheus configuration secrets

2. **Database Management**
   - Ensures MariaDB database creation via `MariaDBDatabase` CR
   - Manages database account via `MariaDBAccount` CR
   - Runs database synchronization jobs (`watcher-db-sync`)
   - Creates database purge CronJob for periodic cleanup

3. **Child Resource Orchestration**
   - Creates and manages `WatcherAPI` CR
   - Creates and manages `WatcherDecisionEngine` CR
   - Creates and manages `WatcherApplier` CR
   - Passes configuration secrets to child resources

4. **Configuration Management**
   - Generates service configuration from templates
   - Creates sub-level secrets containing database credentials, transport URLs, and service passwords
   - Manages custom configuration overrides

#### Reconciliation Flow

1. Initialize status conditions
2. Ensure RBAC (ServiceAccount, Role, RoleBinding)
3. Create MariaDB database and account
4. Create RabbitMQ TransportURL (RPC)
5. Optionally create notification TransportURL
6. Validate input secrets (passwords, Prometheus config)
7. Create Keystone service
8. Generate service configuration
9. Run `db-sync` job
10. Create database purge CronJob
11. Create `WatcherAPI` CR
12. Create `WatcherDecisionEngine` CR
13. Create `WatcherApplier` CR
14. Update Ready condition based on child conditions

#### Status Conditions

- `DBReadyCondition`: Database resources are ready
- `DBSyncReadyCondition`: Database synchronization completed
- `InputReadyCondition`: Input secrets validated
- `ServiceConfigReadyCondition`: Service configuration generated
- `KeystoneServiceReadyCondition`: Keystone service registered
- `ReadyCondition`: Overall readiness (mirrors child conditions)

#### Key Features

- **Finalizer Management**: Properly cleans up MariaDB, KeystoneService, and Prometheus secret finalizers
- **Dual Transport URLs**: Supports separate RPC and notification message buses
- **Hash Tracking**: Tracks configuration changes via hash maps to trigger updates
- **Condition Mirroring**: Mirrors child CR conditions to parent status

---

### 2. WatcherAPI Controller

**File**: `controllers/watcherapi_controller.go`

**Custom Resource**: `WatcherAPI`

#### Purpose

Manages the Watcher API service deployment, which provides the REST API interface for the Watcher service.

#### Main Responsibilities

1. **API Service Deployment**
   - Creates StatefulSet for API pods with configurable replicas
   - Manages API configuration secrets
   - Handles TLS certificate configuration (internal and public endpoints)
   - Configures Apache httpd virtual hosts for API endpoints

2. **Service Exposure**
   - Creates Kubernetes Service resources for internal and public endpoints
   - Manages service ports (default: 9322)
   - Configures ingress annotations for public access
   - Handles TLS termination for both endpoints

3. **Keystone Integration**
   - Creates `KeystoneEndpoint` CR for service catalog registration
   - Manages endpoint URLs (internal and public)
   - Ensures Keystone service is available before proceeding

4. **Dependencies Management**
   - Validates Memcached availability for caching
   - Checks KeystoneAPI availability
   - Validates TLS certificates (CA bundle and endpoint certs)
   - Manages Prometheus configuration

#### Reconciliation Flow

1. Validate and hash input secrets
2. Ensure Memcached is ready
3. Generate service configuration (`watcher.conf`)
4. Validate TLS certificates (if enabled)
5. Create hash of all inputs
6. Deploy StatefulSet with API service
7. Wait for deployment to be ready
8. Expose API via Services (internal and public)
9. Create KeystoneEndpoint for service catalog
10. Mark Ready when all sub-conditions are true

#### Status Conditions

- `InputReadyCondition`: Input secrets validated
- `MemcachedReadyCondition`: Memcached is ready
- `ServiceConfigReadyCondition`: Service configuration generated
- `TLSInputReadyCondition`: TLS certificates validated
- `DeploymentReadyCondition`: StatefulSet is ready
- `ReadyCondition`: Overall readiness

#### Key Features

- **StatefulSet**: Uses StatefulSet for stable network identity
- **Topology Support**: Integrates with Topology CR for pod placement
- **HTTPS Support**: Full TLS support for both internal and public endpoints
- **Service Catalog Integration**: Automatic registration in Keystone service catalog

---

### 3. WatcherDecisionEngine Controller

**File**: `controllers/watcherdecisionengine_controller.go`

**Custom Resource**: `WatcherDecisionEngine`

#### Purpose

Manages the Watcher Decision Engine service, which analyzes infrastructure metrics from monitoring systems and creates optimization action plans based on configured strategies.

#### Main Responsibilities

1. **Decision Engine Deployment**
   - Creates StatefulSet for decision engine pods
   - Configures resource limits and requests
   - Manages service configuration secrets

2. **Monitoring Integration**
   - Connects to Prometheus for infrastructure metrics collection
   - Configures Prometheus CA certificate if provided
   - Validates Prometheus endpoint configuration

3. **OpenStack Service Integration**
   - Tracks Keystone endpoint URLs for dependent services (e.g., Cinder)
   - Hashes endpoint URLs to detect changes
   - Triggers restarts when service endpoints change

4. **Configuration Management**
   - Generates decision engine configuration
   - Configures database connection
   - Sets up messaging (RabbitMQ)
   - Configures Keystone authentication

#### Reconciliation Flow

1. Validate input secrets (service password, transport URL, database credentials)
2. Validate Prometheus configuration secret
3. Ensure Memcached is ready
4. Generate decision engine configuration
5. Hash Keystone endpoint URLs for dependent services
6. Create deployment input hash
7. Deploy StatefulSet
8. Mark Ready when deployment is ready

#### Status Conditions

- `InputReadyCondition`: Input secrets validated
- `MemcachedReadyCondition`: Memcached is ready
- `ServiceConfigReadyCondition`: Service configuration generated
- `DeploymentReadyCondition`: StatefulSet is ready
- `ReadyCondition`: Overall readiness

#### Key Features

- **Endpoint URL Hashing**: Monitors Keystone endpoints for dependent services to detect infrastructure changes
- **Prometheus Integration**: Full Prometheus metrics collection with CA certificate support
- **Dynamic Reconfiguration**: Detects changes in dependent service endpoints and triggers pod restarts

---

### 4. WatcherApplier Controller

**File**: `controllers/watcherapplier_controller.go`

**Custom Resource**: `WatcherApplier`

#### Purpose

Manages the Watcher Applier service, which executes the optimization action plans generated by the Decision Engine.

#### Main Responsibilities

1. **Applier Service Deployment**
   - Creates StatefulSet for applier pods
   - Manages service configuration
   - Handles resource allocation

2. **Configuration Management**
   - Generates applier configuration
   - Configures database connection
   - Sets up RabbitMQ messaging
   - Configures Keystone authentication

3. **Dependency Management**
   - Validates Memcached availability
   - Checks KeystoneAPI availability
   - Manages TLS CA bundle configuration

#### Reconciliation Flow

1. Validate input secrets
2. Ensure Memcached is ready
3. Generate applier configuration
4. Create deployment input hash
5. Handle Topology requirements
6. Deploy StatefulSet
7. Mark Ready when deployment is ready

#### Status Conditions

- `InputReadyCondition`: Input secrets validated
- `MemcachedReadyCondition`: Memcached is ready
- `ServiceConfigReadyCondition`: Service configuration generated
- `DeploymentReadyCondition`: StatefulSet is ready
- `ReadyCondition`: Overall readiness

#### Key Features

- **Focused Architecture**: Simpler service without external API endpoints
- **Topology Support**: Integrates with Topology CR for pod placement
- **Notification Support**: Optionally configured with notification bus for event publishing

---

## Common Components

### ReconcilerBase

**File**: `controllers/watcher_common.go`

Provides shared functionality used by all controllers:

- **Client Management**: Kubernetes client and typed client access
- **Secret Validation**: `ensureSecret()` validates secrets and computes hashes
- **Memcached Integration**: `ensureMemcached()` ensures Memcached availability
- **Topology Management**: `ensureTopology()` handles topology configurations
- **Configuration Generation**: `GenerateConfigsGeneric()` for template-based config generation
- **Constants**: Service labels, field selectors, and error definitions

---

## Design Patterns

### 1. Condition-Based State Management

All controllers use typed condition states to track reconciliation progress. Each major step in the reconciliation process updates a specific condition, allowing users and operators to understand the exact state of the deployment.

### 2. Hash-Based Change Detection

Controllers track changes using hash maps stored in the CR status:

```go
instance.Status.Hash = map[string]string{
    "input": <hash of all input resources>,
    common.InputHashName: <merged environment hash>,
}
```

When hashes change, StatefulSets are automatically redeployed with updated configuration.

### 3. Finalizer Management

All controllers implement proper cleanup using Kubernetes finalizers:
- Database resources are cleaned up before CR deletion
- Memcached finalizers are managed appropriately
- Topology finalizers are removed when no longer needed
- Keystone resources are deregistered on deletion

### 4. Owner References

Child resources use controller references for automatic garbage collection:

```go
controllerutil.SetControllerReference(parent, child, r.Scheme)
```

When a parent CR is deleted, all owned child resources are automatically cleaned up.

### 5. Deferred Status Updates

All controllers use the defer pattern to ensure status is always updated, even if an error occurs:

```go
defer func() {
    condition.RestoreLastTransitionTimes(&instance.Status.Conditions, savedConditions)
    helper.PatchInstance(ctx, instance)
}()
```

---

## Resource Dependencies

### External Dependencies

All controllers integrate with other OpenStack operators:

- **MariaDB Operator**: `MariaDBDatabase`, `MariaDBAccount` (for database management)
- **Infra Operator**: `TransportURL` (RabbitMQ), `Memcached`, `Topology`
- **Keystone Operator**: `KeystoneService`, `KeystoneAPI`, `KeystoneEndpoint`
- **Kubernetes Core**: `Secret`, `ServiceAccount`, `Role`, `RoleBinding`, `Job`, `CronJob`, `StatefulSet`, `Service`

### Dependency Flow

```
MariaDB → Database & Account
RabbitMQ → TransportURL (RPC & Notification)
Keystone → Service & Endpoints
Memcached → Token caching & service state
Topology → Pod placement and affinity
```

---

## Controller Interaction Flow

```
User creates Watcher CR
        ↓
Watcher Controller reconciles:
  1. Creates MariaDB resources
  2. Creates RabbitMQ TransportURLs
  3. Creates Keystone Service
  4. Runs db-sync Job
  5. Creates WatcherAPI CR → WatcherAPI Controller reconciles
  6. Creates WatcherDecisionEngine CR → DecisionEngine Controller reconciles
  7. Creates WatcherApplier CR → Applier Controller reconciles
        ↓
Child controllers create StatefulSets
        ↓
Pods start running Watcher services
        ↓
WatcherAPI exposes endpoints via Services
        ↓
KeystoneEndpoint registers API in service catalog
        ↓
All conditions become Ready
        ↓
Watcher CR status shows Ready=True
```

---

## Special Features

### Database Synchronization

The Watcher controller creates a Kubernetes Job to run `watcher-db-sync`, which initializes and migrates the database schema. The job definition is in `pkg/watcher/dbsync.go`.

### Database Purge

A CronJob is created for periodic database cleanup to prevent unbounded growth. The CronJob definition is in `pkg/watcher/dbpurgecronjob.go`.

### TLS Support

WatcherAPI supports complete TLS configuration:
- **CA Bundle**: Common trust anchor for certificate validation
- **Internal TLS**: Separate secret for internal endpoint certificates
- **Public TLS**: Separate secret for public endpoint certificates
- **Apache Configuration**: TLS configured in httpd virtual hosts

### Topology Integration

All child controllers support Kubernetes topology configurations:
- Node affinity rules for pod placement
- Zone and region awareness
- Finalizer management on Topology CRs
- LastAppliedTopology tracking for change detection

### Memcached Integration

All services integrate with Memcached for caching:
- Keystone token caching to reduce authentication overhead
- Service state caching for improved performance
- Supports TLS and mTLS for secure connections
- Server list configuration with INET format

### Prometheus Monitoring

Decision Engine and API services connect to Prometheus:
- Prometheus host/port configuration
- Optional CA certificate for secure connections
- Volume mounts for CA certificates
- Template-based configuration parameters

---

## Configuration Templates

Controllers use a template-based configuration system with files in the `templates/` directory:

- **`watcher.conf`**: Main Watcher service configuration
- **`00-default.conf`**: Apache default configuration for API service
- **`watcher-blank.conf`**: Blank template for custom configurations

### Template Parameters

Templates support parameters including:
- `DatabaseConnection`: MariaDB connection string
- `TransportURL`: RabbitMQ RPC connection
- `NotificationURL`: Optional notification bus connection
- `KeystoneAuthURL`: Keystone authentication endpoint
- `ServiceUser`/`ServicePassword`: Service credentials
- `MemcachedServers`: Memcached server list
- `PrometheusHost`/`PrometheusPort`: Monitoring endpoints
- `APIPublicPort`: API service port
- `CaFilePath`: CA certificate path
- `QuorumQueues`: RabbitMQ quorum queue settings

---

## RBAC Configuration

### Watcher Controller Permissions

- **ServiceAccounts, Roles, RoleBindings**: Full CRUD for RBAC setup
- **SecurityContextConstraints**: Use `anyuid` SCC
- **Pods, Jobs, CronJobs**: Full lifecycle management
- **Custom Resources**: Manage MariaDB, Keystone, Transport, and child Watcher resources

### Child Controller Permissions

- **StatefulSets, Services, Secrets**: Full lifecycle management
- **KeystoneEndpoints**: Service catalog integration
- **External Resources**: Watch Memcached, Topology, KeystoneAPI

---

## Error Handling

All controllers implement robust error handling:

1. **Pre-defined Error Variables**: Static, err113-compliant error definitions
2. **Condition-Based Reporting**: Errors automatically update condition states
3. **Proper Requeuing**: Failed reconciliations trigger automatic retry
4. **Cleanup on Failure**: Finalizers ensure proper cleanup even on errors
5. **Status Preservation**: `LastTransitionTime` preserved for unchanged conditions

---

## Webhooks

All Custom Resources include validation and defaulting webhooks defined in `api/v1beta1/*_webhook.go`:

- **Watcher Webhook**: Validates specification and sets defaults
- **WatcherAPI Webhook**: Validates API configuration and TLS settings
- **WatcherDecisionEngine Webhook**: Validates decision engine configuration
- **WatcherApplier Webhook**: Validates applier configuration

Webhooks provide admission control to prevent invalid configurations from being created.

---

## Testing

The project includes comprehensive functional tests:

- **Location**: `tests/functional/`
- **Framework**: KUTTL (Kubernetes Test Tool)
- **Coverage**: Tests for each controller and integration scenarios

---

## File Structure

```
controllers/
├── watcher_controller.go              # Main orchestrator controller
├── watcherapi_controller.go           # API service controller
├── watcherdecisionengine_controller.go # Decision engine controller
├── watcherapplier_controller.go       # Applier service controller
└── watcher_common.go                  # Shared utilities and helpers

pkg/
├── watcher/                           # Watcher-specific logic (jobs, volumes, etc.)
├── watcherapi/                        # API StatefulSet definition and logic
├── watcherdecisionengine/             # Decision engine StatefulSet definition
└── watcherapplier/                    # Applier StatefulSet definition

api/v1beta1/
├── watcher_types.go                   # Watcher CR definition
├── watcherapi_types.go                # WatcherAPI CR definition
├── watcherdecisionengine_types.go     # WatcherDecisionEngine CR definition
├── watcherapplier_types.go            # WatcherApplier CR definition
├── conditions.go                      # Condition type definitions
└── *_webhook.go                       # Webhook implementations

templates/
├── watcher.conf                       # Main service configuration template
├── 00-default.conf                    # Apache default configuration
└── watcher-blank.conf                 # Blank configuration template
```

---

## Conclusion

The watcher-operator implements a sophisticated multi-controller architecture following Kubernetes operator best practices:

- **Separation of Concerns**: Each controller has a clear, focused responsibility
- **Resource Lifecycle Management**: Proper creation, update, and deletion handling
- **Robust Error Handling**: Comprehensive error detection and status reporting
- **Security**: Full TLS support and RBAC integration
- **OpenStack Integration**: Seamless integration with MariaDB, Keystone, and RabbitMQ operators
- **State Tracking**: Condition-based status for transparent operation visibility
- **Advanced Features**: Topology awareness, Prometheus monitoring, and notification support

This architecture enables both day-1 (deployment) and day-2 (operational management) capabilities for the OpenStack Watcher service on Kubernetes/OpenShift platforms.
