#!/usr/bin/env bash
# Build and push OpenStack service container images using buildah.
#
# Usage:
#   STREAM=master ./build.sh build all
#   STREAM=hibiscus ./build.sh build watcher
#   STREAM=master ./build.sh build cyborg/cyborg-agent
#   ./build.sh push all
#   ./build.sh list
#
# Streams:
#   A stream defines a set of source repos at specific commits. Streams are
#   defined in sources.txt files with the format:
#     <stream> <name> <repo-url> <branch-to-follow> <pinned-hash>
#
#   Examples:
#     master upper-constraints https://opendev.org/openstack/requirements.git master abc123def456
#     master watcher https://opendev.org/openstack/watcher.git master def789abc012
#     hibiscus upper-constraints https://opendev.org/openstack/requirements.git stable/2024.2 fed321cba654
#     hibiscus watcher https://opendev.org/openstack/watcher.git stable/2024.2 aaa111bbb222
#
#   The <branch-to-follow> field is informational — it records which branch
#   the pinned hash came from. The build always checks out <pinned-hash>.
#
#   sources.txt files can be at three levels:
#     containers/sources.txt                     — global (upper-constraints, shared libs)
#     containers/<project>/sources.txt           — common for all images in the project
#     containers/<project>/<image>/sources.txt   — image-specific extras
#
#   The special name "upper-constraints" is handled differently: instead of
#   cloning the full repo, build.sh fetches just upper-constraints.txt from
#   the repo at the pinned hash and places it in containers/base/.
#
#   The main service package must be listed in sources.txt. Its name is
#   derived from the repo URL (last path component minus .git).
#
# Image naming:
#   Image names are derived as ${IMAGE_PREFIX}-<directory-name>:
#     containers/base/            → openstack-base
#     containers/nova/nova-api/   → openstack-nova-api
#     containers/cyborg/cyborg/   → openstack-cyborg
#   IMAGE_PREFIX defaults to "openstack".
#
# Source management:
#   Sources are cloned into containers/<project>/src/<name>/ based on the
#   stream entries in sources.txt. If the directory already exists, it is
#   used as-is (sources.txt is ignored for that entry). Auto-cloned repos
#   are removed on exit.
#
#   Overrides: place patched dependencies in containers/<project>/src/overrides/<pkg>/
#   These are picked up automatically — no sources.txt entry needed.
#
#   Constraints file:
#     Defined via an "upper-constraints" entry in each project's sources.txt.
#     build.sh fetches the file from the repo at the pinned hash.
#     Each project can have a different constraints file (different streams
#     may track different releases).
#     Alternatively, place it manually at containers/<project>/<CONSTRAINTS_FILE>.
#     Override filename with CONSTRAINTS_FILE env var.
#
# Environment variables:
#   STREAM            Stream name (required for build)
#   REGISTRY          Container registry (default: localhost)
#   NAMESPACE         Registry namespace (default: openstack)
#   TAG               Image tag(s), comma-separated for multiple (default: latest)
#   IMAGE_PREFIX      Prefix for image names (default: openstack)
#   BASE_IMAGE        Base image for the base container (default: registry.access.redhat.com/ubi10/ubi:latest)
#   CONSTRAINTS_URL   Override the URL used to fetch the constraints file
#   CONSTRAINTS_FILE  Constraints filename (default: upper-constraints.txt)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
CONTAINERS_DIR="${REPO_ROOT}/containers"

# Configurable variables
STREAM="${STREAM:-}"
REGISTRY="${REGISTRY:-localhost}"
NAMESPACE="${NAMESPACE:-openstack}"
TAG="${TAG:-latest}"
IMAGE_PREFIX="${IMAGE_PREFIX:-openstack}"
BASE_IMAGE="${BASE_IMAGE:-localhost/openstack/openstack-base}"
CONSTRAINTS_URL="${CONSTRAINTS_URL:-}"
CONSTRAINTS_FILE="${CONSTRAINTS_FILE:-upper-constraints.txt}"

# Discover all buildable images from the directory structure.
discover_images() {
  local images=()

  # base first (if it exists)
  if [[ -f "${CONTAINERS_DIR}/base/Containerfile" ]]; then
    images+=("base")
  fi

  # Then all project/image directories
  for project_dir in "${CONTAINERS_DIR}"/*/; do
    local project=$(basename "${project_dir}")
    [[ "${project}" == "base" ]] && continue

    for image_dir in "${project_dir}"/*/; do
      local image=$(basename "${image_dir}")
      [[ "${image}" == "common" || "${image}" == "src" ]] && continue
      if [[ -f "${image_dir}/Containerfile" ]]; then
        images+=("${project}/${image}")
      fi
    done
  done

  echo "${images[@]}"
}

# Derive the published image name from a directory path
image_name() {
  local dir_name="$1"
  local name
  if [[ "${dir_name}" == */* ]]; then
    name=$(basename "${dir_name}")
  else
    name="${dir_name}"
  fi
  if [[ -n "${IMAGE_PREFIX}" ]]; then
    echo "${IMAGE_PREFIX}-${name}"
  else
    echo "${name}"
  fi
}

# Derive the project name from a directory path
project_name() {
  local dir_name="$1"
  if [[ "${dir_name}" == */* ]]; then
    echo "${dir_name%%/*}"
  fi
}

# Compute the full image tag (first tag, used for display and base image ref)
image_tag() {
  local dir_name="$1"
  local first_tag="${TAG%%,*}"
  echo "${REGISTRY}/${NAMESPACE}/$(image_name "${dir_name}"):${first_tag}"
}

# Generate --tag arguments for all tags (TAG is comma-separated)
image_tag_args() {
  local dir_name="$1"
  local name
  name="$(image_name "${dir_name}")"
  local args=""
  IFS=',' read -ra tags <<< "${TAG}"
  for t in "${tags[@]}"; do
    args="${args} --tag ${REGISTRY}/${NAMESPACE}/${name}:${t}"
  done
  echo "${args}"
}

# Track which projects were auto-cloned so we can clean up
declare -A _AUTO_CLONED=()
declare -A _AUTO_CONSTRAINTS=()

# Remove auto-cloned sources and auto-fetched constraints on exit
cleanup_auto() {
  for src_dir in "${!_AUTO_CLONED[@]}"; do
    echo "--- Removing auto-cloned source: ${src_dir} ---"
    rm -rf "${src_dir}"
  done
  for constraints_file in "${!_AUTO_CONSTRAINTS[@]}"; do
    echo "--- Removing auto-fetched constraints: ${constraints_file} ---"
    rm -f "${constraints_file}"
  done
}
trap cleanup_auto EXIT

# Ensure constraints file exists for a project.
# Looks for an "upper-constraints" entry in the project's sources.txt
# for the current stream and fetches the file at the pinned hash.
ensure_project_constraints() {
  local project="$1"
  local stream="$2"
  local constraints_file="${CONTAINERS_DIR}/${project}/${CONSTRAINTS_FILE}"

  if [[ -f "${constraints_file}" ]]; then
    return
  fi

  # Look for upper-constraints entry in project-level sources.txt
  local project_sources="${CONTAINERS_DIR}/${project}/sources.txt"
  if [[ -f "${project_sources}" ]]; then
    while IFS=' ' read -r entry_stream name url branch pinned_hash; do
      [[ -z "${entry_stream}" || "${entry_stream}" == \#* ]] && continue
      [[ "${entry_stream}" != "${stream}" ]] && continue
      if [[ "${name}" == "upper-constraints" ]]; then
        echo "--- Fetching upper-constraints.txt for ${project} from ${url} at ${pinned_hash} ---"
        local tmp_repo
        tmp_repo=$(mktemp -d)
        git clone --no-checkout "${url}" "${tmp_repo}" 2>/dev/null
        git -C "${tmp_repo}" checkout "${pinned_hash}" -- upper-constraints.txt
        cp "${tmp_repo}/upper-constraints.txt" "${constraints_file}"
        rm -rf "${tmp_repo}"
        _AUTO_CONSTRAINTS["${constraints_file}"]=1
        return
      fi
    done < "${project_sources}"
  fi

  # Fallback to CONSTRAINTS_URL if set
  if [[ -n "${CONSTRAINTS_URL}" ]]; then
    echo "--- Fetching ${CONSTRAINTS_FILE} for ${project} from ${CONSTRAINTS_URL} ---"
    curl -sL "${CONSTRAINTS_URL}" -o "${constraints_file}"
    _AUTO_CONSTRAINTS["${constraints_file}"]=1
    return
  fi

  echo "ERROR: No constraints file at ${constraints_file}" >&2
  echo "       Add an 'upper-constraints' entry to containers/${project}/sources.txt for stream '${stream}'," >&2
  echo "       set CONSTRAINTS_URL, or place the file manually." >&2
  return 1
}

# Clone a repo at a specific commit hash if not already present
# Args: <dest_dir> <url> <pinned_hash>
clone_at_hash() {
  local dest="$1"
  local url="$2"
  local pinned_hash="$3"

  if [[ -d "${dest}" ]]; then
    return
  fi

  mkdir -p "$(dirname "${dest}")"
  echo "--- Cloning ${url} at ${pinned_hash} into ${dest} ---"
  git clone "${url}" "${dest}"
  git -C "${dest}" checkout "${pinned_hash}"
  _AUTO_CLONED["${dest}"]=1
}

# Process sources.txt files for a stream.
# Project-level sources → containers/<project>/src/<name>/
# Image-level sources → containers/<project>/<image>/src/<name>/
# sources.txt format: <stream> <name> <repo-url> <branch-to-follow> <pinned-hash>
ensure_sources_for_stream() {
  local dir_name="$1"   # e.g., "watcher/watcher-api"
  local stream="$2"
  local project="${dir_name%%/*}"

  # Project-level sources.txt → containers/<project>/src/<name>/
  local project_sources="${CONTAINERS_DIR}/${project}/sources.txt"
  if [[ -f "${project_sources}" ]]; then
    local project_src_dir="${CONTAINERS_DIR}/${project}/src"
    while IFS=' ' read -r entry_stream name url branch pinned_hash; do
      [[ -z "${entry_stream}" || "${entry_stream}" == \#* ]] && continue
      [[ "${entry_stream}" != "${stream}" ]] && continue
      [[ "${name}" == "upper-constraints" ]] && continue
      clone_at_hash "${project_src_dir}/${name}" "${url}" "${pinned_hash}"
    done < "${project_sources}"
  fi

  # Image-level sources.txt → containers/<project>/<image>/src/<name>/
  local image_sources="${CONTAINERS_DIR}/${dir_name}/sources.txt"
  if [[ -f "${image_sources}" ]]; then
    local image_src_dir="${CONTAINERS_DIR}/${dir_name}/src"
    while IFS=' ' read -r entry_stream name url branch pinned_hash; do
      [[ -z "${entry_stream}" || "${entry_stream}" == \#* ]] && continue
      [[ "${entry_stream}" != "${stream}" ]] && continue
      [[ "${name}" == "upper-constraints" ]] && continue
      clone_at_hash "${image_src_dir}/${name}" "${url}" "${pinned_hash}"
    done < "${image_sources}"
  fi
}

# Build a single image
build_image() {
  local dir_name="$1"
  local full_tag
  full_tag="$(image_tag "${dir_name}")"
  local project
  project="$(project_name "${dir_name}")"

  echo "=== Building ${full_tag} ==="

  # openstack-base image: no service source, build context is its own directory
  if [[ -z "${project}" ]]; then
    buildah bud \
      $(image_tag_args "${dir_name}") \
      --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
      -f "${CONTAINERS_DIR}/${dir_name}/Containerfile" \
      "${CONTAINERS_DIR}/${dir_name}/"
    return
  fi

  # Ensure stream is set for service images
  if [[ -z "${STREAM}" ]]; then
    echo "ERROR: STREAM is required for building service images." >&2
    echo "       Example: STREAM=master ./build.sh build ${dir_name}" >&2
    return 1
  fi

  # Clone sources for this stream
  ensure_sources_for_stream "${dir_name}" "${STREAM}"

  # Verify main source exists
  local sources_dir="${CONTAINERS_DIR}/${project}/src"
  local src="${sources_dir}/${project}"
  if [[ ! -d "${src}" ]]; then
    echo "ERROR: Main source not found at ${src}" >&2
    echo "       Ensure ${project} is listed in sources.txt for stream '${STREAM}'" >&2
    return 1
  fi

  # Ensure constraints file exists for this project
  ensure_project_constraints "${project}" "${STREAM}"

  buildah bud \
    $(image_tag_args "${dir_name}") \
    --build-arg "CONSTRAINTS_FILE=${CONSTRAINTS_FILE}" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    -f "${CONTAINERS_DIR}/${dir_name}/Containerfile" \
    "${CONTAINERS_DIR}/${project}/"
}

# Check that all tags of an image exist locally
verify_image_exists() {
  local dir_name="$1"
  local name
  name="$(image_name "${dir_name}")"
  local missing=()

  IFS=',' read -ra tags <<< "${TAG}"
  for t in "${tags[@]}"; do
    local full_tag="${REGISTRY}/${NAMESPACE}/${name}:${t}"
    if ! buildah inspect "${full_tag}" &>/dev/null; then
      missing+=("${full_tag}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: The following image tags do not exist locally:" >&2
    for m in "${missing[@]}"; do
      echo "  ${m}" >&2
    done
    return 1
  fi
}

# Push all tags of a single image
push_image() {
  local dir_name="$1"
  local name
  name="$(image_name "${dir_name}")"

  IFS=',' read -ra tags <<< "${TAG}"
  for t in "${tags[@]}"; do
    local full_tag="${REGISTRY}/${NAMESPACE}/${name}:${t}"
    echo "=== Pushing ${full_tag} ==="
    buildah push "${full_tag}"
  done
}

# List all images
list_images() {
  echo "Container images:"
  for dir_name in $(discover_images); do
    local full_tag
    full_tag="$(image_tag "${dir_name}")"
    local project
    project="$(project_name "${dir_name}")"
    if [[ -n "${project}" ]]; then
      echo "  ${dir_name} → ${full_tag}  (project: ${project})"
    else
      echo "  ${dir_name} → ${full_tag}"
    fi
  done
  if [[ -n "${STREAM}" ]]; then
    echo ""
    echo "Stream: ${STREAM}"
  fi
}

# Resolve which images to process
resolve_targets() {
  local target="$1"
  local all_images
  all_images=($(discover_images))

  if [[ "${target}" == "all" ]]; then
    echo "${all_images[@]}"
    return
  fi

  # Exact match
  for dir_name in "${all_images[@]}"; do
    if [[ "${dir_name}" == "${target}" ]]; then
      echo "${target}"
      return
    fi
  done

  # Project prefix match
  local matched=()
  for dir_name in "${all_images[@]}"; do
    if [[ "${dir_name}" == "${target}/"* ]]; then
      matched+=("${dir_name}")
    fi
  done

  if [[ ${#matched[@]} -gt 0 ]]; then
    echo "${matched[@]}"
    return
  fi

  echo "ERROR: Unknown image or project '${target}'" >&2
  echo "Available images:" >&2
  for dir_name in "${all_images[@]}"; do
    echo "  ${dir_name}" >&2
  done
  return 1
}

# Resolve a ref (branch, tag, or commit hash) to a commit hash.
resolve_ref_hash() {
  local url="$1"
  local ref="$2"

  local hash

  # Try as a branch (refs/heads/)
  hash=$(git ls-remote "${url}" "refs/heads/${ref}" 2>/dev/null | cut -f1)

  # Try as a tag — use refs/tags/<ref>^{} to dereference annotated tags
  # to their underlying commit (plain tags return directly)
  if [[ -z "${hash}" ]]; then
    hash=$(git ls-remote "${url}" "refs/tags/${ref}^{}" 2>/dev/null | cut -f1)
  fi
  if [[ -z "${hash}" ]]; then
    hash=$(git ls-remote "${url}" "refs/tags/${ref}" 2>/dev/null | cut -f1)
  fi

  # If it looks like a commit hash already, use it directly
  if [[ -z "${hash}" ]] && [[ "${ref}" =~ ^[0-9a-f]{7,40}$ ]]; then
    hash="${ref}"
  fi

  if [[ -z "${hash}" ]]; then
    echo "ERROR: Could not resolve ref '${ref}' for ${url}" >&2
    return 1
  fi

  echo "${hash}"
}

# Update pinned hashes in a single sources.txt file for the given stream.
update_sources_file() {
  local sources_file="$1"
  local stream="$2"

  if [[ ! -f "${sources_file}" ]]; then
    return
  fi

  local tmp_file
  tmp_file=$(mktemp)
  local updated=0

  while IFS= read -r line; do
    # Preserve comments and blank lines
    if [[ -z "${line}" || "${line}" == \#* ]]; then
      echo "${line}" >> "${tmp_file}"
      continue
    fi

    read -r entry_stream name url branch pinned_hash <<< "${line}"

    # Only update entries for the requested stream
    if [[ "${entry_stream}" != "${stream}" ]]; then
      echo "${line}" >> "${tmp_file}"
      continue
    fi

    # Resolve the latest hash for the branch
    local new_hash
    if new_hash=$(resolve_ref_hash "${url}" "${branch}"); then
      if [[ "${new_hash}" != "${pinned_hash}" ]]; then
        echo "  ${name}: ${pinned_hash:-<empty>} → ${new_hash} (${branch})"
        updated=1
      fi
      echo "${entry_stream} ${name} ${url} ${branch} ${new_hash}" >> "${tmp_file}"
    else
      # Could not resolve — abort
      rm "${tmp_file}"
      return 1
    fi
  done < "${sources_file}"

  if [[ ${updated} -eq 1 ]]; then
    mv "${tmp_file}" "${sources_file}"
  else
    rm "${tmp_file}"
    echo "  (no changes)"
  fi
}

# Update sources.txt files for targets in scope
update_sources() {
  local target="$1"
  local stream="$2"

  if [[ -z "${stream}" ]]; then
    echo "ERROR: STREAM is required for update-sources." >&2
    echo "       Example: STREAM=master ./build.sh update-sources watcher" >&2
    return 1
  fi

  local targets
  targets=($(resolve_targets "${target}"))

  # Collect unique projects from targets
  declare -A projects_seen
  local sources_files=()

  for img in "${targets[@]}"; do
    local project
    project="$(project_name "${img}")"
    [[ -z "${project}" ]] && continue

    # Project-level sources.txt (only process once per project)
    if [[ -z "${projects_seen[$project]:-}" ]]; then
      projects_seen["${project}"]=1
      local project_sources="${CONTAINERS_DIR}/${project}/sources.txt"
      if [[ -f "${project_sources}" ]]; then
        sources_files+=("${project_sources}")
      fi
    fi

    # Image-level sources.txt
    local image_sources="${CONTAINERS_DIR}/${img}/sources.txt"
    if [[ -f "${image_sources}" ]]; then
      sources_files+=("${image_sources}")
    fi
  done

  if [[ ${#sources_files[@]} -eq 0 ]]; then
    echo "No sources.txt files found for target '${target}'"
    return
  fi

  for sf in "${sources_files[@]}"; do
    echo "--- Updating ${sf} (stream: ${stream}) ---"
    if ! update_sources_file "${sf}" "${stream}"; then
      echo "ERROR: Failed to update ${sf}" >&2
      return 1
    fi
  done
}

# Main
ACTION="${1:-}"
TARGET="${2:-all}"

case "${ACTION}" in
  build)
    for img in $(resolve_targets "${TARGET}"); do
      build_image "${img}"
    done
    ;;
  push)
    _push_targets=($(resolve_targets "${TARGET}"))

    # Verify all images and tags exist before pushing any
    echo "--- Verifying all images exist locally ---"
    for img in "${_push_targets[@]}"; do
      verify_image_exists "${img}"
    done

    # All verified — push
    for img in "${_push_targets[@]}"; do
      push_image "${img}"
    done
    ;;
  update-sources)
    update_sources "${TARGET}" "${STREAM}"
    ;;
  list)
    list_images
    ;;
  *)
    echo "Usage: STREAM=<name> $0 {build|push|update-sources|list} [image-name|all]"
    echo ""
    echo "Images (discovered from containers/):"
    for dir_name in $(discover_images); do
      echo "  ${dir_name} → $(image_name "${dir_name}")"
    done
    echo ""
    echo "sources.txt format:"
    echo "  <stream> <name> <repo-url> <branch-to-follow> <pinned-hash>"
    echo ""
    echo "Environment variables:"
    echo "  STREAM            Stream name (required for build)"
    echo "  REGISTRY          Container registry (default: localhost)"
    echo "  NAMESPACE         Registry namespace (default: openstack)"
    echo "  TAG               Image tag(s), comma-separated (default: latest)"
    echo "  IMAGE_PREFIX      Prefix for image names (default: openstack)"
    echo "  BASE_IMAGE        Base image for the base container"
    echo "  CONSTRAINTS_FILE  Constraints filename (default: upper-constraints.txt)"
    echo "  CONSTRAINTS_URL   URL to fetch constraints file if not present locally"
    echo ""
    echo "Source directories: containers/<project>/src/<name>/"
    echo "Overrides:          containers/<project>/src/overrides/<pkg>/"
    exit 1
    ;;
esac
