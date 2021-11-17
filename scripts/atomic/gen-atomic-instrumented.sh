#!/bin/sh
# SPDX-License-Identifier: GPL-2.0

ATOMICDIR=$(dirname $0)

. ${ATOMICDIR}/atomic-tbl.sh

#gen_param_check(meta, arg)
gen_param_check()
{
	local meta="$1"; shift
	local arg="$1"; shift
	local type="${arg%%:*}"
	local name="$(gen_param_name "${arg}")"
	local rw="write"

	case "${type#c}" in
	i) return;;
	esac

	if [ ${type#c} != ${type} ]; then
		# We don't write to constant parameters.
		rw="read"
	elif [ "${meta}" != "s" ]; then
		# An atomic RMW: if this parameter is not a constant, and this atomic is
		# not just a 's'tore, this parameter is both read from and written to.
		rw="read_write"
	fi

	printf "\tinstrument_atomic_${rw}(${name}, sizeof(*${name}));\n"
}

#gen_params_checks(meta, arg...)
gen_params_checks()
{
	local meta="$1"; shift

	while [ "$#" -gt 0 ]; do
		gen_param_check "$meta" "$1"
		shift;
	done
}

# gen_guard(meta, atomic, pfx, name, sfx, order)
gen_guard()
{
	local meta="$1"; shift
	local atomic="$1"; shift
	local pfx="$1"; shift
	local name="$1"; shift
	local sfx="$1"; shift
	local order="$1"; shift

	local atomicname="arch_${atomic}_${pfx}${name}${sfx}${order}"

	local template="$(find_fallback_template "${pfx}" "${name}" "${sfx}" "${order}")"

	# We definitely need a preprocessor symbol for this atomic if it is an
	# ordering variant, or if there's a generic fallback.
	if [ ! -z "${order}" ] || [ ! -z "${template}" ]; then
		printf "defined(${atomicname})"
		return
	fi

	# If this is a base variant, but a relaxed variant *may* exist, then we
	# only have a preprocessor symbol if the relaxed variant isn't defined
	if meta_has_relaxed "${meta}"; then
		printf "!defined(${atomicname}_relaxed) || defined(${atomicname})"
	fi
}

#gen_proto_order_variant(meta, pfx, name, sfx, order, atomic, int, arg...)
gen_proto_order_variant()
{
	local meta="$1"; shift
	local pfx="$1"; shift
	local name="$1"; shift
	local sfx="$1"; shift
	local order="$1"; shift
	local atomic="$1"; shift
	local int="$1"; shift

	local atomicname="${atomic}_${pfx}${name}${sfx}${order}"

	local guard="$(gen_guard "${meta}" "${atomic}" "${pfx}" "${name}" "${sfx}" "${order}")"

	local ret="$(gen_ret_type "${meta}" "${int}")"
	local params="$(gen_params "${int}" "${atomic}" "$@")"
	local checks="$(gen_params_checks "${meta}" "$@")"
	local args="$(gen_args "$@")"
	local retstmt="$(gen_ret_stmt "${meta}")"

	[ ! -z "${guard}" ] && printf "#if ${guard}\n"

cat <<EOF
static __always_inline ${ret}
${atomicname}(${params})
{
${checks}
	${retstmt}arch_${atomicname}(${args});
}
#define ${atomicname} ${atomicname}
EOF

	[ ! -z "${guard}" ] && printf "#endif\n"

	printf "\n"
}

gen_xchg()
{
	local xchg="$1"; shift
	local mult="$1"; shift

	if [ "${xchg%${xchg#try_cmpxchg}}" = "try_cmpxchg" ] ; then

cat <<EOF
#define ${xchg}(ptr, oldp, ...) \\
({ \\
	typeof(ptr) __ai_ptr = (ptr); \\
	typeof(oldp) __ai_oldp = (oldp); \\
	instrument_atomic_write(__ai_ptr, ${mult}sizeof(*__ai_ptr)); \\
	instrument_atomic_write(__ai_oldp, ${mult}sizeof(*__ai_oldp)); \\
	arch_${xchg}(__ai_ptr, __ai_oldp, __VA_ARGS__); \\
})
EOF

	else

cat <<EOF
#define ${xchg}(ptr, ...) \\
({ \\
	typeof(ptr) __ai_ptr = (ptr); \\
	instrument_atomic_write(__ai_ptr, ${mult}sizeof(*__ai_ptr)); \\
	arch_${xchg}(__ai_ptr, __VA_ARGS__); \\
})
EOF

	fi
}

gen_optional_xchg()
{
	local name="$1"; shift
	local sfx="$1"; shift
	local guard="defined(arch_${name}${sfx})"

	[ -z "${sfx}" ] && guard="!defined(arch_${name}_relaxed) || defined(arch_${name})"

	printf "#if ${guard}\n"
	gen_xchg "${name}${sfx}" ""
	printf "#endif\n\n"
}

cat << EOF
// SPDX-License-Identifier: GPL-2.0

// Generated by $0
// DO NOT MODIFY THIS FILE DIRECTLY

/*
 * This file provides wrappers with KASAN instrumentation for atomic operations.
 * To use this functionality an arch's atomic.h file needs to define all
 * atomic operations with arch_ prefix (e.g. arch_atomic_read()) and include
 * this file at the end. This file provides atomic_read() that forwards to
 * arch_atomic_read() for actual atomic operation.
 * Note: if an arch atomic operation is implemented by means of other atomic
 * operations (e.g. atomic_read()/atomic_cmpxchg() loop), then it needs to use
 * arch_ variants (i.e. arch_atomic_read()/arch_atomic_cmpxchg()) to avoid
 * double instrumentation.
 */
#ifndef _ASM_GENERIC_ATOMIC_INSTRUMENTED_H
#define _ASM_GENERIC_ATOMIC_INSTRUMENTED_H

#include <linux/build_bug.h>
#include <linux/compiler.h>
#include <linux/instrumented.h>

EOF

grep '^[a-z]' "$1" | while read name meta args; do
	gen_proto "${meta}" "${name}" "atomic" "int" ${args}
done

grep '^[a-z]' "$1" | while read name meta args; do
	gen_proto "${meta}" "${name}" "atomic64" "s64" ${args}
done

for xchg in "xchg" "cmpxchg" "cmpxchg64" "try_cmpxchg"; do
	for order in "" "_acquire" "_release" "_relaxed"; do
		gen_optional_xchg "${xchg}" "${order}"
	done
done

for xchg in "cmpxchg_local" "cmpxchg64_local" "sync_cmpxchg"; do
	gen_xchg "${xchg}" ""
	printf "\n"
done

gen_xchg "cmpxchg_double" "2 * "

printf "\n\n"

gen_xchg "cmpxchg_double_local" "2 * "

cat <<EOF

#endif /* _ASM_GENERIC_ATOMIC_INSTRUMENTED_H */
EOF
