#!/bin/bash

VERSION='0.0.1'

# Execute this script with 'bash -x SCRIPT' to activate debugging
if [ ${-/*x*/x} == 'x' ]; then
    PS4='+ $(basename ${BASH_SOURCE[0]}):${LINENO} ${FUNCNAME[0]}() |err=$?| \$ '
fi
set -e  # Fail on first error

SELF_NAME="$0"
if [[ "${MACHTYPE}" =~ "msys" ]]; then
    SELF_NAME="${SELF_NAME//\\//}"
    SELF_NAME="${SELF_NAME/[A-Z]://C}"
fi
SELF_NAME="${SELF_NAME#\.}"
SELF_NAME="${SELF_NAME##/*/}"
SELF_NAME="${SELF_NAME#/}"
SELF_NAME="${SELF_NAME%.sh}"
SELF_DIRNAME=$(cd "$(dirname $(type -p "$0"))" ; pwd)

# Includes
source "${SELF_DIRNAME}/../bash-colors/colors2.inc"
source "${SELF_DIRNAME}/../profile_d/.profile.d/echo2.sh"

function _version()
{
    echo "${SELF_NAME} v${VERSION}"
}

function _help() {
    cat <<EOF
Usage:
    ${SELF_NAME} [OPTIONS] cl <sw|sh|wh>

Quickly diff with Perforce on the given CL.
The diff operation to perform can be one of those strings:
    "sw": diff the Shelved file w/ the Workspace file
    "sh": diff the Shelved file w/ the Having file
    "wh": diff the Workspace file w/ the Having file

OPTIONS:
    -v, --version       Display version.
    -h, --help          Display this help.
EOF
}

function _main() {
    args=$(getopt --options hv --longoptions help,version --name "${SELF_NAME}" -- "$@")
    if [ $? -ne 0 ]; then
        >&2 echo "Error: Invalid options"
        exit 2
    fi
    eval set -- "${args}"
    while true; do
        case "$1" in
        -v|--version)
            _version
            exit 0
        ;;
        -h|--help)
            _help
            exit 0
        ;;
        --)
            shift
            break
        ;;
        esac
    done

    if [ $# -ne 2 ]; then
        echo >&2 "Error: You have to give 2 arguments: the CL and an operation"
        _help
        exit 1
    fi

    local changelist=$1
    local operation=$2

    if [ -z "${operation}" ]; then
        echo >&2 "Error: You have to give an operation: sw, sh, wh"
        exit 1
    fi

    local operation_title=""
    case "${operation}" in
        sw)
            operation_title="Shelved vs Workspace"
            ;;
        sh)
            operation_title="Shelved vs Have"
            ;;
        wh)
            operation_title="Workspace vs Have"
            ;;
        *)
            echo >&2 "Error: Unknow operation \"${operation}\""
            exit 1
    esac

    local workspace_output=$(p4 opened -c ${changelist} | tr -d '\r')
    # declare -p workspace_output

    local -a workspace_files=()
    local workspace_name=""
    local workspace_line
    while read workspace_line; do
        extract_file_from_line fic <<< "${workspace_line}"
        workspace_files+=( "${fic}" )
        # Use the 1st workspace file to know the name of the workspace and its user
        if [ -z "${workspace_name}" ]; then
            extract_workspace_name_from_line workspace_name <<< "${workspace_line}"
        fi
    done <<< "${workspace_output}"

    echo "Pending files: ${#workspace_files[@]}" | echo_color ${COLOR_GREEN}
    local fic
    for fic in "${workspace_files[@]}"; do
        echo "<- ${fic}"
    done

    workspace_root=$(p4 clients -e "${workspace_name}" \
        | perl -pe "s,^.*( root )([^']+).*,\$2,g" \
        | sed 's,^ *,,g' \
        | sed 's, *$,,g' \
    )
    workspace_root=$(cygpath -m "${workspace_root}")

    # Move into the workspace root to be ensure a full list of shelved files
    pushd "${workspace_root}" >/dev/null
    local shelved_output=$(p4 files ...@=${changelist} | tr -d '\r')
    popd >/dev/null

    local -a shelved_files=()
    local shelved_line
    while read shelved_line; do
        extract_file_from_line fic <<< "${shelved_line}"
        shelved_files+=( "${fic}" )
    done <<< "${shelved_output}"

    echo "Shelved files: ${#shelved_files[@]}" | echo_color ${COLOR_GREEN}
    for fic in "${shelved_files[@]}"; do
        echo "-> ${fic}"
    done

    echo "${operation_title}" | echo_header_center | echo_color ${COLOR_YELLOW}

    # -dw: to ignore whitespace
    # -dl: to ignore line endings
    # -du: to display a unified diff
    # -ds: to display a summary of the diff
    local diff_option="-dwls"
    if [ "${operation}" == "sw" ]; then
        local -i diff_size=$(( ${#shelved_files[@]} - ${#workspace_files[@]} ))
        if [ ${diff_size} -ne 0 ]; then
            echo "There are more or less files in the shelf than in the workspace: ${#shelved_files[@]} vs ${#workspace_files[@]}" | echo_color ${COLOR_CYAN} ${STYLE_REVERSE}
        fi
        if [ ${diff_size} -gt 0 ]; then
            for fic in "${shelved_files[@]}"; do
                echo "Diff ${fic}" | echo_header_center | echo_color ${COLOR_CYAN}
                is_file_in_array is_present "${fic}" <<< "${workspace_files[@]}"
                if [ ${is_present} -eq 0 ]; then
                    echo -n "File ${fic} "; echo "missing in the workspace" | echo_color ${COLOR_YELLOW} ${STYLE_REVERSE}
                else
                    p4 diff ${diff_option} "${fic}@=${changelist}" "${fic}#none"
                fi
            done
        else
            for fic in "${workspace_files[@]}"; do
                echo "Diff ${fic}" | echo_header_center | echo_color ${COLOR_CYAN}
                is_file_in_array is_present "${fic}" <<< "${shelved_files[@]}"
                if [ ${is_present} -eq 0 ]; then
                    echo -n "File ${fic} "; echo "missing in the shelf" | echo_color ${COLOR_YELLOW} ${STYLE_REVERSE}
                else
                    p4 diff ${diff_option} "${fic}@=${changelist}" "${fic}#none"
                fi
            done
        fi
    elif [ "${operation}" == "sh" ]; then
        local shelved_file
        for shelved_file in "${shelved_files[@]}"; do
            echo "Diff ${shelved_file}" | echo_header_center | echo_color ${COLOR_CYAN}
            p4 diff ${diff_option} "${shelved_file}@=${changelist}" "${shelved_file}#have"
        done
    elif [ "${operation}" == "wh" ]; then
        local workspace_file
        for workspace_file in "${workspace_files[@]}"; do
            echo "Diff ${workspace_file}" | echo_header_center | echo_color ${COLOR_CYAN}
            p4 diff ${diff_option} "${workspace_file}#none" "${workspace_file}#have"
        done
    fi
}

function extract_file_from_line() {
    local -n ret=$1
    ret=$(cat - | perl -pe 's,^([^#]+)#([0-9]+|none)( - ).*,$1,g')
}

function extract_workspace_name_from_line() {
    local -n ret=$1
    ret=$(cat - | perl -pe 's,^(.+)( - ).*( by )([^@]+)@(.+)$,$5,g')
}

function is_file_in_array() {
    local -n ret=$1
    local arr=" "$(cat -)" "
    local search_file=$2
    # declare -p arr search_file

    ret=$(grep -cF " ${search_file} " <<< "${arr}")
    # declare -p ret
}

_main "$@"
