#!/bin/bash
set -e

# Regex pattern to match semantic versioning (e.g., 1.2.3)
SEMVER_REGEX="^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"

# Function to get the latest stable and experimental versions from the Factorio API
get_latest_versions() {
    local api_url="https://factorio.com/api/latest-releases"
    # Get the latest stable and experimental versions using jq to parse JSON
    stable_online_version=$(curl -s "$api_url" | jq '.stable.headless' -r)
    experimental_online_version=$(curl -s "$api_url" | jq '.experimental.headless' -r)
}

# Function to get the SHA256 checksum for a given version
get_sha256() {
    local version=$1
    # Fetch the SHA256 checksum from Factorio's sha256sums page
    curl -s "https://factorio.com/download/sha256sums/" | grep -E "(factorio_headless_x64_|factorio-headless_linux_)${version}.tar.xz" | awk '{print $1}'
}

# Function to get the current stable and latest versions from buildinfo.json
get_current_versions() {
    stable_current_version=$(jq -r 'with_entries(select(contains({value:{tags:["stable"]}}))) | keys | .[0]' buildinfo.json)
    latest_current_version=$(jq -r 'with_entries(select(contains({value:{tags:["latest"]}}))) | keys | .[0]' buildinfo.json)
}

# Function to extract a specific component (major, minor, patch) from a version string
get_semver_component() {
    local ver=$1
    local type=$2
    if [[ "$ver" =~ $SEMVER_REGEX ]]; then
        local major=${BASH_REMATCH[1]}
        local minor=${BASH_REMATCH[2]}
        local patch=${BASH_REMATCH[3]}
    fi
    # Return the requested component (major, minor, or patch)
    case $type in
        major) echo "$major" ;;
        minor) echo "$minor" ;;
        patch) echo "$patch" ;;
    esac
}

# Function to update buildinfo.json with the new stable and experimental versions
update_buildinfo_json() {
    local tmpfile=$(mktemp)

    # Remove the "latest" tag from the current latest version
    jq --arg latest_current_version "$latest_current_version" 'with_entries(if .key == $latest_current_version then .value.tags |= . - ["latest"] else . end)' buildinfo.json > "$tmpfile"
    mv "$tmpfile" buildinfo.json

    # Update the stable version
    if [[ $stableOnlineVersionShort == "$stableCurrentVersionShort" ]]; then
        # If the major.minor version is the same, update the existing entry
        jq --arg stable_current_version "$stable_current_version" \
           --arg stable_online_version "$stable_online_version" \
           --arg sha256 "$stable_sha256" \
           'with_entries(if .key == $stable_current_version then .key |= $stable_online_version | .value.sha256 |= $sha256 | .value.tags |= . - [$stable_current_version] + [$stable_online_version] else . end)' \
           buildinfo.json > "$tmpfile"
    else
        # If the major.minor version is different, create a new entry for the stable version
        jq --arg stable_current_version "$stable_current_version" \
           --arg stable_online_version "$stable_online_version" \
           --arg sha256 "$stable_sha256" \
           --arg stableOnlineVersionShort "$stableOnlineVersionShort" \
           --arg stableOnlineVersionMajor "$stableOnlineVersionMajor" \
           'with_entries(if .key == $stable_current_version then .value.tags |= . - ["latest","stable",$stableOnlineVersionMajor] else . end) | \
           to_entries | . + [{ key: $stable_online_version, value: { sha256: $sha256, tags: ["latest","stable",("stable-" + $stable_online_version),$stableOnlineVersionMajor,$stableOnlineVersionShort,$stable_online_version]}}] | from_entries' \
           buildinfo.json > "$tmpfile"
    fi
    mv "$tmpfile" buildinfo.json

    # Update the experimental version if it's different from the stable version
    if [[ $experimental_online_version != "$stable_online_version" ]]; then
        if [[ $stableOnlineVersionShort == "$experimentalOnlineVersionShort" ]]; then
            # If the experimental version shares the same major.minor as the stable version
            jq --arg experimental_online_version "$experimental_online_version" \
               --arg stable_online_version "$stable_online_version" \
               --arg sha256 "$experimental_sha256" \
               'with_entries(if .key == $stable_online_version then .value.tags |= . - ["latest"] else . end) | \
               to_entries | . + [{ key: $experimental_online_version, value: { sha256: $sha256, tags: ["latest", $experimental_online_version]}}] | from_entries' \
               buildinfo.json > "$tmpfile"
        else
            # If the experimental version has a different major.minor
            jq --arg experimental_online_version "$experimental_online_version" \
               --arg stable_online_version "$stable_online_version" \
               --arg sha256 "$experimental_sha256" \
               --arg experimentalOnlineVersionShort "$experimentalOnlineVersionShort" \
               --arg experimentalOnlineVersionMajor "$experimentalOnlineVersionMajor" \
               'with_entries(if .key == $stable_online_version then .value.tags |= . - ["latest"] else . end) | \
               to_entries | . + [{ key: $experimental_online_version, value: { sha256: $sha256, tags: ["latest",$experimentalOnlineVersionMajor,$experimentalOnlineVersionShort,$experimental_online_version]}}] | from_entries' \
               buildinfo.json > "$tmpfile"
        fi
        mv "$tmpfile" buildinfo.json
    fi
}

# Function to update the README.md file with the latest version tags
update_readme_tags() {
    readme_tags=$(jq --sort-keys 'keys[]' buildinfo.json | tac | while read -r line; do
        # Generate a formatted list of tags for each version
        tags="$tags\n* "$(jq --sort-keys ".$line.tags | sort | .[]" buildinfo.json | sed 's/"/`/g' | sed ':a; /$/N; s/\n/, /; ta')
    done && printf "%s\n\n" "$tags")

    # Update the README.md file by replacing the autogenerated tags section
    perl -i -0777 -pe "s/<!-- start autogeneration tags -->.+<!-- end autogeneration tags -->/<!-- start autogeneration tags -->$readme_tags<!-- end autogeneration tags -->/s" README.md
}

# Function to update the Docker Compose file with the latest stable version and checksum
update_docker_compose() {
    local docker_compose_path="docker/docker-compose.yml"
    local sov="VERSION=${stable_online_version}"
    local sha="SHA256=${stable_sha256}"
    # Update the VERSION and SHA256 arguments in the Docker Compose file
    yq -i '.services.factorio.build.args[0] = env(sov)' "$docker_compose_path"
    yq -i '.services.factorio.build.args[1] = env(sha)' "$docker_compose_path"
}

# Function to commit changes to the Git repository
commit_changes() {
    # Configure Git user details
    git config user.name github-actions[bot]
    git config user.email 41898282+github-actions[bot]@users.noreply.github.com
    # Add updated files to Git and commit the changes
    git add buildinfo.json README.md docker/docker-compose.yml
    git commit -a -m "Auto Update Factorio to stable version: ${stable_online_version} experimental version: ${experimental_online_version}"
    # Tag the latest version and push changes to the repository
    git tag -f latest
    git push
    git push origin --tags -f
}

# Main function to orchestrate the update process
main() {
    # Get the latest online versions
    get_latest_versions
    # Exit if versions couldn't be retrieved
    if [[ -z "$stable_online_version" || -z "$experimental_online_version" ]]; then exit; fi
    # Get the current versions from buildinfo.json
    get_current_versions
    # Exit if the current versions match the latest online versions
    if [[ "$stable_current_version" == "$stable_online_version" && "$latest_current_version" == "$experimental_online_version" ]]; then exit; fi

    # Get the SHA256 checksums for the stable and experimental versions
    stable_sha256=$(get_sha256 "$stable_online_version")
    experimental_sha256=$(get_sha256 "$experimental_online_version")

    # Extract major and minor components of the versions for comparison
    stableOnlineVersionMajor=$(get_semver_component "$stable_online_version" major)
    stableOnlineVersionMinor=$(get_semver_component "$stable_online_version" minor)
    experimentalOnlineVersionMajor=$(get_semver_component "$experimental_online_version" major)
    experimentalOnlineVersionMinor=$(get_semver_component "$experimental_online_version" minor)
    stableCurrentVersionMajor=$(get_semver_component "$stable_current_version" major)
    stableCurrentVersionMinor=$(get_semver_component "$stable_current_version" minor)
    latestCurrentVersionMajor=$(get_semver_component "$latest_current_version" major)
    latestCurrentVersionMinor=$(get_semver_component "$latest_current_version" minor)

    # Create short version strings for comparison (e.g., major.minor)
    stableOnlineVersionShort=$stableOnlineVersionMajor.$stableOnlineVersionMinor
    experimentalOnlineVersionShort=$experimentalOnlineVersionMajor.$experimentalOnlineVersionMinor
    stableCurrentVersionShort=$stableCurrentVersionMajor.$stableCurrentVersionMinor
    latestCurrentVersionShort=$latestCurrentVersionMajor.$latestCurrentVersionMinor

    # Update buildinfo.json, README.md, and Docker Compose file
    update_buildinfo_json
    update_readme_tags
    update_docker_compose
    # Commit the changes to the repository
    commit_changes
}

# Call the main function
main "$@"
