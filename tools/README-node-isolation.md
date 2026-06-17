# Node Isolation for DataMate Deployment

This document describes the node isolation feature for commercial DataMate deployment.

## Overview

Node isolation allows you to dedicate specific Kubernetes nodes for DataMate components, ensuring:
- **Resource isolation**: DataMate pods only run on designated nodes
- **Performance guarantee**: Avoid resource competition with other workloads
- **Hardware specialization**: Use specific nodes for GPU/NPU workloads

## Features

- Interactive node selection with keyboard navigation (↑/↓ or j/k)
- Automatic label application: `node-role.kubernetes.io/datamate=true`
- Optional taint application: `node-role.kubernetes.io/datamate=true:NoSchedule`
- Helm argument generation for nodeSelector and tolerations
- Cross-platform support (Linux, macOS)

## Usage

### During Installation

The node isolation setup is automatically triggered during `./install.sh`:

```bash
cd tools
./install.sh -n model-engine
```

You will see an interactive prompt:

```
Configure dedicated nodes for DataMate deployment?
This will apply labels and taints to selected nodes.

1. Yes - Configure nodes interactively
2. No - Use default scheduling (recommended for development)

Enter choice [default: 2]: 
```

**Options:**
- Choose `1` to enter interactive node selection
- Choose `2` or press Enter to skip (recommended for dev/test environments)

### Interactive Node Selection

If you choose to configure nodes, you'll see an interactive menu:

```
=====================================
  DataMate Node Setup
=====================================

Select nodes for DataMate deployment

  → [ ] node-1 (Ready) [datamate]
    [x] node-2 (Ready)
    [ ] node-3 (NotReady)

Navigation: ↑/k: up  ↓/j: down  space: toggle  enter: confirm  q: quit

Selected: 1/3 nodes
```

**Controls:**
- **↑/k**: Move up
- **↓/j**: Move down
- **Space**: Toggle selection
- **Enter**: Confirm selection
- **q**: Quit and skip setup

### Skip Node Setup

To skip node isolation during installation:

```bash
./install.sh --skip-node-setup
```

### Manual Node Setup

You can also run node setup independently:

```bash
cd tools
./node-setup.sh --namespace model-engine
```

**Options:**
- `--namespace <ns>`: Target namespace (default: model-engine)
- `--dry-run`: Show what would be done without applying changes
- `--skip-taint`: Only apply labels, skip taints

### Node Cleanup

To remove node labels and taints:

```bash
cd tools
./node-cleanup.sh --namespace model-engine
```

**Options:**
- `--namespace <ns>`: Target namespace
- `--dry-run`: Show what would be removed
- `--nodes <node1,node2>`: Clean specific nodes (default: auto-detect labeled nodes)
- `--label-key <key>`: Custom label key (default: node-role.kubernetes.io/datamate)

During uninstallation, node cleanup is automatically triggered unless skipped:

```bash
./uninstall.sh --skip-node-cleanup
```

## How It Works

### Labels and Taints

When you select nodes, the script applies:

**Label:**
```bash
kubectl label node <node-name> node-role.kubernetes.io/datamate=true --overwrite
```

**Taint (optional):**
```bash
kubectl taint node <node-name> node-role.kubernetes.io/datamate=true:NoSchedule --overwrite
```

### Helm Configuration

The script generates Helm arguments and saves them to `/tmp/datamate-helm-args.sh`:

```bash
export HELM_NODE_SELECTOR_ARGS="--set-string global.nodeSelector.node-role\.kubernetes\.io/datamate=true ..."
export HELM_TOLERATIONS_ARGS="--set-string global.tolerations[0].key=node-role.kubernetes.io/datamate ..."
```

These arguments are automatically sourced by `install.sh` and applied to all DataMate components:
- backend
- backend-python
- database
- frontend
- gateway
- runtime
- ray-cluster (head, worker, npuGroup, gpuGroup)
- kuberay-operator

### Taint Effect

The `NoSchedule` taint effect ensures:
- **Only pods with matching tolerations** can be scheduled on these nodes
- **Regular pods without tolerations** are scheduled elsewhere
- **Existing pods remain running** (NoSchedule only affects new pods)

## Best Practices

### Production Deployment

For production environments:
1. **Dedicate 3+ nodes** for DataMate (HA requirement)
2. **Apply both labels and taints** for strict isolation
3. **Use nodes with sufficient resources** (CPU, memory, storage)
4. **Consider hardware specialization** (GPU/NPU nodes for ML workloads)

### Development/Testing

For dev/test environments:
1. **Skip node isolation** (use default scheduling)
2. **Or apply labels only** (skip taints for flexibility)
3. **Single node is acceptable** (no HA requirement)

### Mixed Workloads

If you want DataMate to coexist with other workloads:
1. **Apply labels only** (use `--skip-taint`)
2. **DataMate pods prefer labeled nodes** (nodeSelector)
3. **Other pods can still run** on these nodes (no taint blocking)

## Troubleshooting

### Nodes Not Selected

If nodes aren't being selected properly:
1. Check node status: `kubectl get nodes`
2. Verify kubectl connectivity: `kubectl cluster-info`
3. Ensure you're in a terminal (not piped input)

### Pods Not Scheduling

If DataMate pods fail to schedule after node isolation:
1. Check node labels: `kubectl get nodes --show-labels`
2. Check node taints: `kubectl describe node <node-name>`
3. Verify tolerations in Helm values
4. Check pod events: `kubectl describe pod <pod-name> -n <namespace>`

### Cleanup Failed

If cleanup fails to remove labels/taints:
1. Manual removal: 
   ```bash
   kubectl label node <node-name> node-role.kubernetes.io/datamate-
   kubectl taint node <node-name> node-role.kubernetes.io/datamate=true:NoSchedule-
   ```
2. Check for stuck pods: `kubectl get pods -n <namespace>`

## Implementation Details

### File Structure

```
tools/
├── node-setup.sh       # Interactive node selection and configuration
├── node-cleanup.sh     # Remove labels and taints
├── install.sh          # Modified to call node-setup.sh
├── uninstall.sh        # Modified to call node-cleanup.sh
└── README-node-isolation.md  # This documentation
```

### Integration Points

**install.sh:**
- Line 309-313: Node setup call before sealed-secrets installation
- Line 275-285: Helm args sourcing in install_datamate()
- Line 384: `--skip-node-setup` flag handler

**uninstall.sh:**
- Line 63-66: Node cleanup call after Helm uninstall
- Line 117: `--skip-node-cleanup` flag handler

### Helm Arguments Structure

**NodeSelector:**
```yaml
global:
  nodeSelector:
    node-role.kubernetes.io/datamate: "true"
backend:
  nodeSelector:
    node-role.kubernetes.io/datamate: "true"
# ... (same for all services)
```

**Tolerations:**
```yaml
global:
  tolerations:
    - key: node-role.kubernetes.io/datamate
      operator: Equal
      value: "true"
      effect: NoSchedule
backend:
  tolerations:
    - key: node-role.kubernetes.io/datamate
      operator: Equal
      value: "true"
      effect: NoSchedule
# ... (same for all services)
```

## Comparison with Open Source Version

The commercial version node isolation is **equivalent** to the open source version in DataMate repository:

| Feature | Open Source | Commercial |
|---------|-------------|------------|
| Interactive selection | ✓ | ✓ |
| Keyboard navigation | ✓ | ✓ |
| Label application | ✓ | ✓ |
| Taint application | ✓ | ✓ |
| Helm args generation | ✓ | ✓ |
| Integration point | Makefile `node-setup` target | install.sh automatic call |
| Cleanup script | ✓ | ✓ |

**Key difference:**
- **Open source**: Manual invocation via `make node-setup`
- **Commercial**: Automatic invocation during `./install.sh`

## Related Documentation

- [DataMate Open Source Node Setup](https://github.com/modelengine-group/datamate/blob/main/scripts/k8s/node-setup.sh)
- [Kubernetes Node Selection](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)
- [Kubernetes Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)