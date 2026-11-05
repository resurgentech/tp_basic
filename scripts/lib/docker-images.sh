# Sourced by the docker oracle scripts. Exports the pinned docker_images
# commit (DI_SHA) once and hands out the path, so the Ansible side is built
# from that commit and never from the sibling's working tree.
#
#   di_export <root> [<outroot>]   sets DI_FULL_SHA and DI_DIR (build/docker_images/<sha>);
#                      returns 2 with a message on stderr on any failure
#
# The export holds docker-bake.hcl, Dockerfiles, scripts and .dockerignore.
# A complete export carries a .export-complete marker and is reused; a new
# one is extracted beside it and renamed into place, so a killed run never
# leaves a half export and parallel runs cannot see one.

di_export() {
    local root=$1 out=${2:-$1} repo sha tmp dest
    repo=$root/../docker_images
    if [[ -z ${DI_SHA:-} ]]; then
        echo "DI_SHA is not set: the docker_images commit the Ansible side is built from (just passes ported_docker_images; or DI_SHA=<sha> $0 ...)" >&2
        return 2
    fi
    sha=$(git -C "$repo" rev-parse --verify "$DI_SHA^{commit}" 2>/dev/null) || {
        echo "$DI_SHA is not a commit in $repo: fetch it or set DI_SHA" >&2
        return 2
    }
    DI_FULL_SHA=$sha
    DI_DIR=$out/build/docker_images/$sha
    dest=$DI_DIR
    [[ -f $dest/.export-complete ]] && return 0
    mkdir -p "$out/build/docker_images"
    tmp=$(mktemp -d "$out/build/docker_images/.tmp.XXXXXX")
    if ! { git -C "$repo" archive "$sha" docker-bake.hcl Dockerfiles scripts .dockerignore | tar -x -C "$tmp"; }; then
        rm -rf "$tmp"
        echo "export of $sha from $repo failed" >&2
        return 2
    fi
    : >"$tmp/.export-complete"
    chmod 755 "$tmp"
    if ! mv -T "$tmp" "$dest" 2>/dev/null; then
        # another run won the rename; use its export if complete
        rm -rf "$tmp"
        [[ -f $dest/.export-complete ]] || { echo "could not place export at $dest" >&2; return 2; }
    fi
    echo "docker_images: exported $sha to $dest" >&2
}
