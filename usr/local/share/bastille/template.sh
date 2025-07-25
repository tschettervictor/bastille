#!/bin/sh
#
# SPDX-License-Identifier: BSD-3-Clause
#
# Copyright (c) 2018-2025, Christer Edwards <christer.edwards@gmail.com>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# * Redistributions of source code must retain the above copyright notice, this
#   list of conditions and the following disclaimer.
#
# * Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
#
# * Neither the name of the copyright holder nor the names of its
#   contributors may be used to endorse or promote products derived from
#   this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

. /usr/local/share/bastille/common.sh

usage() {
    error_notify "Usage: bastille template [option(s)] TARGET [--convert] TEMPLATE"
    cat << EOF

    Options:

    -a | --auto           Auto mode. Start/stop jail(s) if required.
    -x | --debug          Enable debug mode.

EOF
    exit 1
}

post_command_hook() {

    _jail=$1
    _cmd=$2
    _args=$3

    case $_cmd in
        rdr)
            echo -e ${_args}
    esac
}

get_arg_name() {
    echo "${1}" | sed -E 's/=.*//'
}

parse_arg_value() {
    # Parses the value after = and then escapes back/forward slashes and single quotes in it. -- cwells
    echo "${1}" | sed -E 's/[^=]+=?//' | sed -e 's/\\/\\\\/g' -e 's/\//\\\//g' -e 's/'\''/'\''\\'\'\''/g' -e 's/&/\\&/g' -e 's/"//g'
}

get_arg_value() {
    _name_value_pair="${1}"
    shift
    _arg_name="$(get_arg_name "${_name_value_pair}")"

    # Remaining arguments in $@ are the script arguments, which take precedence. -- cwells
    for _script_arg in "$@"; do
        case ${_script_arg} in
            --arg)
                # Parse whatever is next. -- cwells
                _next_arg='true' ;;
            *)
                if [ "${_next_arg}" = 'true' ]; then # This is the parameter after --arg. -- cwells
                    _next_arg=''
                    if [ "$(get_arg_name "${_script_arg}")" = "${_arg_name}" ]; then
                        parse_arg_value "${_script_arg}"
                        return
                    fi
                fi
                ;;
        esac
    done

    # Check the ARG_FILE if one was provided. --cwells
    if [ -n "${ARG_FILE}" ]; then
        # To prevent a false empty value, only parse the value if this argument exists in the file. -- cwells
        if grep "^${_arg_name}=" "${ARG_FILE}" > /dev/null 2>&1; then
            parse_arg_value "$(grep "^${_arg_name}=" "${ARG_FILE}")"
            return
        fi
    fi

    # Return the default value, which may be empty, from the name=value pair. -- cwells
    parse_arg_value "${_name_value_pair}"
}

render() {
    _file_path="${1}/${2}"
    if [ -d "${_file_path}" ]; then # Recursively render every file in this directory. -- cwells
        echo "Rendering Directory: ${_file_path}"
        find "${_file_path}" \( -type d -name .git -prune \) -o -type f
        find "${_file_path}" \( -type d -name .git -prune \) -o -type f -print0 | eval "xargs -0 sed -i '' ${ARG_REPLACEMENTS}"
    elif [ -f "${_file_path}" ]; then
        echo "Rendering File: ${_file_path}"
        eval "sed -i '' ${ARG_REPLACEMENTS} '${_file_path}'"
    else
        warn "[WARNING]: Path not found for render: ${2}"
    fi
}

line_in_file() {
    _jailpath="${1}"
    _filepath="$(echo ${2} | awk '{print $2}')"
    _line="$(echo ${2} | awk '{print $1}')"
    if [ -f "${_jailpath}/${_filepath}" ]; then
        if ! grep -qxF "${_line}" "${_jailpath}/${_filepath}"; then
            echo "${_line}" >> "${_jailpath}/${_filepath}"
	fi
    else
        warn "[WARNING]: Path not found for line_in_file: ${_filepath}"
    fi
}

# Handle options.
AUTO=0
while [ "$#" -gt 0 ]; do
    case "${1}" in
        -h|--help|help)
            usage
            ;;
        -a|--auto)
            AUTO=1
            shift
            ;;
        -x|--debug)
            enable_debug
            shift
            ;;
        -*) 
            for _opt in $(echo ${1} | sed 's/-//g' | fold -w1); do
                case ${_opt} in
                    a) AUTO=1 ;;
                    x) enable_debug ;;
                    *) error_exit "[ERROR]: Unknown Option: \"${1}\"" ;; 
                esac
            done
            shift
            ;;
        *)
            break
            ;;
    esac
done

if [ "$#" -lt 2 ]; then
    usage
fi

TARGET="${1}"
TEMPLATE="${2}"
bastille_template=${bastille_templatesdir}/${TEMPLATE}
if [ -z "${HOOKS}" ]; then
    HOOKS='LIMITS INCLUDE PRE FSTAB PF PKG OVERLAY CONFIG SYSRC SERVICE CMD RENDER'
fi

bastille_root_check

# We set the target only if it is not --convert
# Special case conversion of hook-style template files into a Bastillefile. -- cwells
if [ "${TARGET}" = '--convert' ]; then
    if [ -d "${TEMPLATE}" ]; then # A relative path was provided. -- cwells
        cd "${TEMPLATE}" || error_exit "[ERROR]: Failed to change to directory: ${TEMPLATE}"
    elif [ -d "${bastille_template}" ]; then
        cd "${bastille_template}" || error_exit "[ERROR]: Failed to change to directory: ${TEMPLATE}"
    else
        error_exit "[ERROR]: Template not found: ${TEMPLATE}"
    fi

    echo "Converting template: ${TEMPLATE}"

    HOOKS="ARG ${HOOKS}"
    for _hook in ${HOOKS}; do
        if [ -s "${_hook}" ]; then
            # Default command is the hook name and default args are the line from the file. -- cwells
            _cmd="${_hook}"
            _args_template='${_line}'

            # Replace old hook names with Bastille command names. -- cwells
            case ${_hook} in
                CONFIG|OVERLAY)
                    _cmd='CP'
                    _args_template='${_line} /'
                    ;;
                FSTAB)
                    _cmd='MOUNT' ;;
                PF)
                    _cmd='RDR' ;;
                PRE)
                    _cmd='CMD' ;;
            esac

            while read _line; do
                if [ -z "${_line}" ]; then
                    continue
                fi
                eval "_args=\"${_args_template}\""
                echo "${_cmd} ${_args}" >> Bastillefile
            done < "${_hook}"
            echo '' >> Bastillefile
            rm "${_hook}"
        fi
    done

    info "\nTemplate converted: ${TEMPLATE}"
    exit 0
else
    set_target "${TARGET}"
fi

case ${TEMPLATE} in
    http?://*/*/*)
        TEMPLATE_DIR=$(echo "${TEMPLATE}" | awk -F / '{ print $4 "/" $5 }')
        if [ ! -d "${bastille_templatesdir}/${TEMPLATE_DIR}" ]; then
            info "Bootstrapping ${TEMPLATE}..."
            if ! bastille bootstrap "${TEMPLATE}"; then
                error_exit "[ERROR]: Failed to bootstrap template: ${TEMPLATE}"
            fi
        fi
        TEMPLATE="${TEMPLATE_DIR}"
        bastille_template=${bastille_templatesdir}/${TEMPLATE}
        ;;
    */*)
        if [ ! -d "${bastille_templatesdir}/${TEMPLATE}" ]; then
            if [ ! -d ${TEMPLATE} ]; then
                error_exit "[ERROR]: ${TEMPLATE} not found."
            else
                bastille_template=${TEMPLATE}
            fi
        fi
        ;;
    *)
        error_exit "[ERROR]: Template name/URL not recognized."
esac

# Check for an --arg-file parameter. -- cwells
for _script_arg in "$@"; do
    case ${_script_arg} in
        --arg-file)
            # Parse whatever is next. -- cwells
            _next_arg='true' ;;
        *)
            if [ "${_next_arg}" = 'true' ]; then # This is the parameter after --arg-file. -- cwells
                _next_arg=''
                ARG_FILE="${_script_arg}"
                break
            fi
            ;;
    esac
done

if [ -n "${ARG_FILE}" ] && [ ! -f "${ARG_FILE}" ]; then
    error_exit "[ERROR]: File not found: ${ARG_FILE}"
fi

for _jail in ${JAILS}; do

    (

    check_target_is_running "${_jail}" || if [ "${AUTO}" -eq 1 ]; then
        bastille start "${_jail}"
    else
        info "\n[${_jail}]:"
        error_notify "Jail is not running."
        error_continue "Use [-a|--auto] to auto-start the jail."
    fi

    info "\n[${_jail}]:"
    
    echo "Applying template: ${TEMPLATE}..."

    ## get jail ip4 and ip6 values
    bastille_jail_path=$(/usr/sbin/jls -j "${_jail}" path)
    if [ "$(bastille config ${_jail} get vnet)" != 'enabled' ]; then
        _jail_ip4="$(bastille config ${_jail} get ip4.addr | sed 's/,/ /g' | awk '{print $1}')"
        _jail_ip6="$(bastille config ${_jail} get ip6.addr | sed 's/,/ /g' | awk '{print $1}')"
    fi
    ## remove value if ip4 was not set or disabled, otherwise get value
    if [ "${_jail_ip4}" = "not set" ] || [ "${_jail_ip4}" = "disable" ]; then
        _jail_ip4='' # In case it was -. -- cwells
    elif echo "${_jail_ip4}" | grep -q "|"; then
        _jail_ip4="$(echo ${_jail_ip4} | awk -F"|" '{print $2}' | sed -E 's#/[0-9]+$##g')"
    else
        _jail_ip4="$(echo ${_jail_ip4} | sed -E 's#/[0-9]+$##g')"
    fi
    ## remove value if ip6 was not set or disabled, otherwise get value
    if [ "${_jail_ip6}" = "not set" ] || [ "${_jail_ip6}" = "disable" ]; then
        _jail_ip6='' # In case it was -. -- cwells
    elif echo "${_jail_ip6}" | grep -q "|"; then
        _jail_ip6="$(echo ${_jail_ip6} | awk -F"|" '{print $2}' | sed -E 's#/[0-9]+$##g')"
    else
        _jail_ip6="$(echo ${_jail_ip6} | sed -E 's#/[0-9]+$##g')"
    fi
    # print error when both ip4 and ip6 are not set
    if { [ "${_jail_ip4}" = "not set" ] || [ "${_jail_ip4}" = "disable" ]; } && \
       { [ "${_jail_ip6}" = "not set" ] || [ "${_jail_ip6}" = "disable" ]; } then
        error_notify "Jail IP not found: ${_jail}"
    fi
    
    ## TARGET
    if [ -s "${bastille_template}/TARGET" ]; then
        if grep -qw "${_jail}" "${bastille_template}/TARGET"; then
            info "TARGET: !${_jail}."
            echo
            continue
        fi
    if ! grep -Eq "(^|\b)(${_jail}|ALL)($|\b)" "${bastille_template}/TARGET"; then
            info "TARGET: ?${_jail}."
            echo
            continue
        fi
    fi

    # Build a list of sed commands like this: -e 's/${username}/root/g' -e 's/${domain}/example.com/g'
    # Values provided by default (without being defined by the user) are listed here. -- cwells
    ARG_REPLACEMENTS="-e 's/\${jail_ip4}/${_jail_ip4}/g' -e 's/\${jail_ip6}/${_jail_ip6}/g' -e 's/\${JAIL_NAME}/${_jail}/g'"
    # This is parsed outside the HOOKS loop so an ARG file can be used with a Bastillefile. -- cwells
    if [ -s "${bastille_template}/ARG" ]; then
        while read _line; do
            if [ -z "${_line}" ]; then
                continue
            fi
            _arg_name=$(get_arg_name "${_line}")
            _arg_value=$(get_arg_value "${_line}" "$@")
            if [ -z "${_arg_value}" ]; then
	        # Just warn, not exit
	        # This is becasue some ARG values do not need to be set
	        # Example: Choosing DHCP for VNET jails does not set GATEWAY
                warn "[WARNING]: No value provided for arg: ${_arg_name}"
            fi
            ARG_REPLACEMENTS="${ARG_REPLACEMENTS} -e 's/\${${_arg_name}}/${_arg_value}/g'"
        done < "${bastille_template}/ARG"
    fi

    if [ -s "${bastille_template}/Bastillefile" ]; then
        # Ignore blank lines and comments. -- cwells
        SCRIPT=$(awk '{ if (substr($0, length, 1) == "\\") { printf "%s", substr($0, 1, length-1); } else { print $0; } }' "${bastille_template}/Bastillefile" | grep -v '^[[:blank:]]*$' | grep -v '^[[:blank:]]*#')
        # Use a newline as the separator. -- cwells
        IFS='
'
        set -f
        for _line in ${SCRIPT}; do
            # First word converted to lowercase is the Bastille command. -- cwells
            _cmd=$(echo "${_line}" | awk '{print tolower($1);}')
            # Rest of the line with "arg" variables replaced will be the arguments. -- cwells
            _args=$(echo "${_line}" | awk -F '[ ]' '{$1=""; sub(/^ */, ""); print;}' | eval "sed ${ARG_REPLACEMENTS}")

            # Apply overrides for commands/aliases and arguments. -- cwells
            case $_cmd in
                arg) # This is a template argument definition. -- cwells
                    _arg_name=$(get_arg_name "${_args}")
                    _arg_value=$(get_arg_value "${_args}" "$@")
                    if [ -z "${_arg_value}" ]; then
                        warn "[WARNING]: No value provided for arg: ${_arg_name}"
                    fi
                    # Build a list of sed commands like this: -e 's/${username}/root/g' -e 's/${domain}/example.com/g'
                    ARG_REPLACEMENTS="${ARG_REPLACEMENTS} -e 's/\${${_arg_name}}/${_arg_value}/g'"
                    continue
                    ;;
                cmd)
                    # Escape single-quotes in the command being executed. -- cwells
                    _args=$(echo "${_args}" | sed "s/'/'\\\\''/g")
                    # Allow redirection within the jail. -- cwells
                    _args="sh -c '${_args}'"
                    ;;
                cp|copy)
                    _cmd='cp'
                    # Convert relative "from" path into absolute path inside the template directory. -- cwells
                    if [ "${_args%"${_args#?}"}" != '/' ] && [ "${_args%"${_args#??}"}" != '"/' ]; then
                        _args="${bastille_template}/${_args}"
                    fi
                    ;;
                fstab|mount)
                    _cmd='mount' ;;
                include)
                    _cmd='template' ;;
                overlay)
                    _cmd='cp'
                    _args="${bastille_template}/${_args} /"
                    ;;
                pkg)
                    _args="install -y ${_args}" ;;
                render) # This is a path to one or more files needing arguments replaced by values. -- cwells
                    render "${bastille_jail_path}" "${_args}"
                    continue
                    ;;
                lif|lineinfile|line_in_file)
                    line_in_file "${bastille_jail_path}" "${_args}"
                    continue
                    ;;
            esac

            if ! eval "bastille ${_cmd} ${_jail} ${_args}"; then
                set +f
                unset IFS
                error_exit "[ERROR]: Failed to execute command: ${_cmd}"
            fi

            post_command_hook "${_jail}" "${_cmd}" "${_args}"
        done
        set +f
        unset IFS
    fi

    for _hook in ${HOOKS}; do
        if [ -s "${bastille_template}/${_hook}" ]; then
            # Default command is the lowercase hook name and default args are the line from the file. -- cwells
            _cmd=$(echo "${_hook}" | awk '{print tolower($1);}')
            _args_template='${_line}'

            # Override default command/args for some hooks. -- cwells
            case ${_hook} in
                CONFIG)
	            # Just warn, not exit
	            # This is becasue some ARG values do not need to be set
	            # Example: Choosing DHCP for VNET jails does not set GATEWAY
                    warn "CONFIG deprecated; rename to OVERLAY."
                    _args_template='${bastille_template}/${_line} /'
                    _cmd='cp' ;;
                FSTAB)
                    _cmd='mount' ;;
                INCLUDE)
                    _cmd='template' ;;
                OVERLAY)
                    _args_template='${bastille_template}/${_line} /'
                    _cmd='cp' ;;
                PF)
                    info "NOT YET IMPLEMENTED."
                    continue ;;
                PRE)
                    _cmd='cmd' ;;
                RENDER) # This is a path to one or more files needing arguments replaced by values. -- cwells
                    render "${bastille_jail_path}" "${_line}"
                    continue
                    ;;
            esac

            info "[${_jail}]:${_hook} -- START"
            if [ "${_hook}" = 'CMD' ] || [ "${_hook}" = 'PRE' ]; then
                bastille cmd "${_jail}" /bin/sh < "${bastille_template}/${_hook}" || error_exit "[ERROR]: Failed to execute command."
            elif [ "${_hook}" = 'PKG' ]; then
                bastille pkg "${_jail}" install -y "$(cat "${bastille_template}/PKG")" || error_exit "[ERROR]: Failed to install packages."
                bastille pkg "${_jail}" audit -F
            else
                while read _line; do
                    if [ -z "${_line}" ]; then
                        continue
                    fi
                    # Replace "arg" variables in this line with the provided values. -- cwells
                    _line=$(echo "${_line}" | eval "sed ${ARG_REPLACEMENTS}")
                    eval "_args=\"${_args_template}\""
                    bastille "${_cmd}" "${_jail}" "${_args}" || error_exit "[ERROR]: Failed to execute command."
                done < "${bastille_template}/${_hook}"
            fi
            info "[${_jail}]:${_hook} -- END"
            echo
        fi
    done
    
    info "\nTemplate applied: ${TEMPLATE}"

    ) &
	
    bastille_running_jobs "${bastille_process_limit}"
	
done
wait
