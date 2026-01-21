#!/bin/bash

VERSION='0.0.3'

# Execute this script with 'bash -x SCRIPT' to activate debugging
if [ ${-/*x*/x} == 'x' ]; then
    # PS4='+ $(basename ${BASH_SOURCE[0]}):${LINENO} ${FUNCNAME[0]}() |err=$?| \$ '
    PS4='+ :${LINENO} ${FUNCNAME[0]}() |err=$?| \$ '
fi
# set -e  # Fail on first error

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
    ${SELF_NAME} [OPTIONS] client_name

Delete a p4 client.
The client can be owned by someone else (you need the 'admin' permission to delete such client).
The client may target a different host.
The client may have CL pending, in which case this script will revert the pending changes.

OPTIONS:
    -v, --version       Display version.
    -h, --help          Display this help.
        --delete-force       Use the '-f' (force) p4 option when performing any deletion.
        --delete-pending-cl  If the client has pending changelists, try to delete them.
        --revert-opened      If the client has opened files, try to revert them.
EOF
}

OPT_DELETE_FORCE=false
OPT_DELETE_PENDING_CL=false
OPT_REVERT_OPENED=false

function _main() {
    args=$(getopt --options hv --longoptions help,version,delete-force,delete-pending-cl,revert-opened --name "${SELF_NAME}" -- "$@")
    if [ $? -ne 0 ]; then
        >&2 echo "Error: Invalid options"
        exit 2
    fi
    eval set -- "${args}"
    while true; do
        case "$1" in
        --delete-force)
            OPT_DELETE_FORCE=true
            shift
        ;;
        --delete-pending-cl)
            OPT_DELETE_PENDING_CL=true
            shift
        ;;
        --revert-opened)
            OPT_REVERT_OPENED=true
            shift
        ;;
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

    if [ $# -ne 1 ]; then
        echo >&2 "Error: You have to give the client_name"
        _help
        exit 1
    fi

    local client_name=$1
    local delete_output=$(p4_client_delete "${client_name}")
    detect_client_deletion_success is_deleted <<< "${delete_output}"
    if [ $is_deleted -gt 0 ]; then
        echo "${delete_output}" | echo_color ${COLOR_GREEN}
    else
        detect_pending_changes has_pending <<< "${delete_output}"
        detect_opened_files has_opened_files <<< "${delete_output}"
        if [ $has_pending -ge 1 ]; then
            echo "The client ${client_name} has pending changelist(s)" | echo_color ${COLOR_CYAN}
            $OPT_DELETE_PENDING_CL && delete_pending_changelists are_all_changelists_deleted "${client_name}"
            if [ ${are_all_changelists_deleted} ]; then
                # Try again to delete the client
                delete_output=$(p4_client_delete "${client_name}")
                detect_client_deletion_success is_deleted <<< "${delete_output}"
                if [ $is_deleted -eq 0 ]; then
                    echo "Unable to delete the client \"${client_name}\" even after its pending CLs have been deleted!" | echo_color ${COLOR_RED}
                fi
            fi
        fi
        if [ $has_opened_files -ge 1 ]; then
            echo "The client ${client_name} has opened file(s)" | echo_color ${COLOR_CYAN}
            $OPT_REVERT_OPENED && revert_opened_files are_all_files_reverted "${client_name}"
            if [ ${are_all_files_reverted} ]; then
                # Try again to delete the client
                delete_output=$(p4_client_delete "${client_name}")
                detect_client_deletion_success is_deleted <<< "${delete_output}"
                if [ $is_deleted -eq 0 ]; then
                    echo "Unable to delete the client \"${client_name}\" even after its opened files have been reverted!" | echo_color ${COLOR_RED}
                fi
            fi
        fi
    fi
}

function p4_client_delete() {
    local client_name=$1
    p4 client -d "${client_name}" 2>&1
}

function detect_client_deletion_success() {
    local -n ret=$1
    ret=$(cat - | grep -cE 'Client .* deleted\.')
}

function detect_pending_changes() {
    local -n ret=$1
    ret=$(cat - | grep -cF ' has pending changes.')
}

function detect_opened_files() {
    local -n ret=$1
    # ret=$(cat - | grep -cF ' - edit change ')
    ret=$(cat - | grep -cF ' has files opened. ')
}

function p4_list_pending_changelists() {
    local client_name=$1
    p4 changes -c "${client_name}" -s pending | tr -d '\r' | awk -F' ' '{print $2}' | xargs
}

function p4_list_changelists_with_opened_files() {
    local client_name=$1
    p4 opened -C "${client_name}" | tr -d '\r' | perl -p -e 's,.* - edit change ([0-9]+).*,$1,;' -e 's,.* - edit default change .*,default,;' | sort -u | xargs
}

function delete_pending_changelists() {
    local -n ret=$1
    local client_name=$2

    ret=true
    echo "Let's try to delete the pending changelists" | echo_color ${COLOR_CYAN}

    local pending_changelists=( $(p4_list_pending_changelists "${client_name}") )
    local changelist
    local delete_output=''

    for changelist in "${pending_changelists[@]}"; do
        delete_output=$(p4_delete_pending_changelist "${client_name}" "${changelist}")
        detect_changelist_deletion_success is_deleted <<< "${delete_output}"
        if [ $is_deleted -eq 0 ]; then
            # Display the CL deletion output so the user know what is the issue.
            echo "${delete_output}" | echo_color ${COLOR_YELLOW}
            ret=false
        else
            echo "changelist #${changelist} deleted" | echo_color ${COLOR_GREEN}
        fi
    done
}

function revert_opened_files() {
    local -n res=$1
    local client_name=$2

    ret=true
    echo "Let's try to revert the opened files" | echo_color ${COLOR_CYAN}

    local changelists_w_opened=( $(p4_list_changelists_with_opened_files "${client_name}") )
    local changelist
    local revert_output=''

    for changelist in "${changelists_w_opened[@]}"; do
        revert_output=$(p4_revert_changelist "${client_name}" "${changelist}")
        detect_permission_issue is_not_enough_permission <<< "${revert_output}"
        if [ $is_not_enough_permission -ge 1 ]; then
            echo "${revert_output}" | echo_color ${COLOR_RED}
        else
            detect_changelist_revert_success is_revert <<< "${revert_output}"
            if [ $is_revert -eq 0 ]; then
                echo "${revert_output}" | echo_color ${COLOR_YELLOW}
                ret=false
            else
                echo "changelist #${changelist} reverted" | echo_color ${COLOR_GREEN}
            fi
        fi
    done
}

function detect_changelist_deletion_success() {
    local -n ret=$1
    ret=$(cat - | grep -cF '') # TODO
}

function detect_changelist_revert_success() {
    local -n ret=$1
    ret=$(cat - | grep -cF '') # TODO
}

function detect_permission_issue() {
    local -n ret=$1
    ret=$(cat - | grep -cF "You don't have permission for this operation.")
}

function p4_delete_pending_changelist() {
    local client_name=$1
    local changelist=$2

    local force=''
    $OPT_DELETE_FORCE && force='-f'

    p4 -c "${client_name}" change -d ${force} ${changelist} 2>&1
}

# TODO It may be needed to give the depot-path of the file to revert
function p4_revert_changelist() {
    local client_name=$1
    local changelist=$2
    # local depot_path_to_file=$3

    # Revert the opened files (reverted in the server metadata w/o altering the
    # local files) using the '-k' p4 revert option.
    #
    # -k: Keep workspace files; the file(s) are removed from any changelists and
    # P4 Server records that the files as being no longer open, but the file(s)
    # are unchanged in the client workspace.

    if [ "${changelist}" == "default" ]; then
        p4 revert -k -C "${client_name}" ... 2>&1
    else
        # TODO Which revert is needed?
        # p4 revert -k -c ${changelist} -C "${client_name}" "${depot_path_to_file}" 2>&1
        p4 revert -k -c ${changelist} -C "${client_name}" ... 2>&1
        # p4 revert -k -C "${client_name}" ... 2>&1
        # p4 revert -k -C "${client_name}" "${depot_path_to_added_file}" 2>&1
    fi
}

_main "$@"
