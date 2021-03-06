#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright 2019 Joyent, Inc.
#

#
# Bootstraps the consistent hash ring for electric-moray.
#

set -o xtrace
set -o errexit
set -o pipefail

SOURCE="${BASH_SOURCE[0]}"
if [[ -h $SOURCE ]]; then
    SOURCE="$(readlink "$SOURCE")"
fi
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
PROFILE=/root/.bashrc
SVC_ROOT=/opt/smartdc/electric-moray

source ${DIR}/scripts/util.sh
source ${DIR}/scripts/services.sh

export PATH=$SVC_ROOT/bin:$SVC_ROOT/build/node/bin:/opt/local/bin:/usr/sbin/:/usr/bin:$PATH
export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

FASH=/opt/smartdc/electric-moray/node_modules/.bin/fash
LEVELDB_DIR_PARENT=/electric-moray/chash
LEVELDB_DIR=$LEVELDB_DIR_PARENT/leveldb-
SAPI_URL=$(mdata-get SAPI_URL)
[[ -n $SAPI_URL ]] || fatal "no SAPI_URL found"
sleep 10 # wait 10 seconds for dns to setup, this is so lame but otherwise will resolve in dns resolution errors.

#
# Load the Manta Application object from SAPI.  If this request fails, it will
# be retried until the smf(5) method timeout expires for the "mdata:execute"
# service.
#
while :; do
    if ! sapi_res=$(curl --max-time 60 --ipv4 -sSf \
      -H 'Accept: application/json' -H 'Content-Type: application/json' \
      "$SAPI_URL/applications?name=manta&include_master=true"); then
        printf 'WARNING: could not download SAPI application (retrying)\n' >&2
        sleep 2
        continue
    fi

    if ! napps=$(json length <<< "$sapi_res") || [[ $napps != '1' ]]; then
        printf 'WARNING: found "%s" SAPI applications (retry)\n' "$napps" >&2
        sleep 2
        continue
    fi

    if ! manta_app=$(json 0 <<< "$sapi_res") || [[ -z $manta_app ]]; then
        printf 'WARNING: failed to parse "manta" SAPI application (retry)\n' >&2
        sleep 2
        continue
    fi

    break
done

HASH_RING_IMAGE=$(json metadata.HASH_RING_IMAGE <<< "$manta_app")
[[ -n $HASH_RING_IMAGE ]] || fatal "no HASH_RING_IMAGE found"
HASH_RING_FILE=/var/tmp/$(uuid -v4).tar.gz
export SDC_IMGADM_URL=$(json metadata.HASH_RING_IMGAPI_SERVICE <<< "$manta_app")
[[ -n $SDC_IMGADM_URL ]] || fatal "no SDC_IMGADM_URL found"
ZONE_UUID=$(/usr/bin/zonename)
ZFS_PARENT_DATASET=zones/$ZONE_UUID/data
ZFS_DATASET=$ZFS_PARENT_DATASET/electric-moray

function manta_hack_syslog_conf {
    # Hack.  See MANTA-2165
    local conf=/etc/syslog.conf
    if [[ -e $conf ]]; then
        sed -ir 's/\/var\/log\/authlog/\/var\/log\/auth\.log/' $conf
        sed -ir 's/\/var\/log\/maillog/\/var\/log\/postfix\.log/' $conf
    fi
}

function manta_setup_determine_instances {
    ELECTRIC_MORAY_INSTANCES=1
    local size=`json -f ${METADATA} SIZE`
    if [ "$size" = "lab" ] || [ "$size" = "production" ]
    then
        ELECTRIC_MORAY_INSTANCES=4
    fi
}

function manta_setup_leveldb_hash_ring {
    # get the hash ring image
    /opt/smartdc/electric-moray/node_modules/.bin/sdc-imgadm get-file $HASH_RING_IMAGE -o $HASH_RING_FILE
    local leveldb_ring_parent_dir=/var/tmp/$(uuid -v4)
    local leveldb_ring=$leveldb_ring_parent_dir/hash_ring
    mkdir -p $leveldb_ring_parent_dir
    tar -xzf $HASH_RING_FILE -C $leveldb_ring_parent_dir
    # delete the dataset if it already exists
    set +o errexit
    zfs destroy -rf $ZFS_DATASET
    set -o errexit
    # create the dataset
    zfs create -o canmount=noauto $ZFS_DATASET
    [[ $? -eq 0 ]] || fatal "unable to setup leveldb"
    # create the mountpoint dir
    mkdir -p $LEVELDB_DIR_PARENT
    [[ $? -eq 0 ]] || fatal "unable to setup leveldb"
    # set the mountpoint
    zfs set mountpoint=$LEVELDB_DIR_PARENT $ZFS_DATASET
    [[ $? -eq 0 ]] || fatal "unable to setup leveldb"
    # mount the dataset
    zfs mount $ZFS_DATASET
    [[ $? -eq 0 ]] || fatal "unable to setup leveldb"
    # build the list of leveldb locations
    local leveldb_dirs
    for (( i=1; i<=$ELECTRIC_MORAY_INSTANCES; i++ ))
    do
        leveldb_dirs[$i]=$LEVELDB_DIR$(expr 2020 + $i)
    done

    # try and load the topology from disk, if the load fails, we should error
    # out since we expect the topology to be there in the configure script
    for dir in "${leveldb_dirs[@]}"
    do
        cp -R $leveldb_ring $dir
        [[ $? -eq 0 ]] || fatal "unable to setup leveldb"
        # test with get-node on the newly created ring
        $FASH get-node -l $dir -b leveldb yunong
        [[ $? -eq 0 ]] || fatal "unable to setup leveldb"
    done
    ZFS_SNAPSHOT=$ZFS_DATASET@$(date +%s)000
    zfs snapshot $ZFS_SNAPSHOT
    [[ $? -eq 0 ]] || fatal "unable to setup leveldb"
}

function manta_setup_electric_moray {
    #Build the list of ports.  That'll be used for everything else.
    local ports
    local kangs
    local statuses
    for (( i=1; i<=$ELECTRIC_MORAY_INSTANCES; i++ )); do
        ports[$i]=`expr 2020 + $i`
        kangs[$i]=`expr 3020 + $i`
        statuses[$i]=`expr 4020 + $i`
    done

    #Regenerate the registrar config with the real ports included
    #(the bootstrap one just includes 2020 alone)
    IFS=','
    local portlist=$(echo "${ports[*]}" | sed 's/^,//')
    local RTPL=$SVC_ROOT/sapi_manifests/registrar/template
    sed -e "s/@@PORTS@@/${portlist}/g" ${RTPL}.in > ${RTPL}

    #Wait until config-agent regenerates config.json before restarting
    #registrar
    svcadm restart config-agent
    while [[ /opt/smartdc/registrar/etc/config.json -ot ${RTPL} ]]; do
        sleep 1
    done
    svcadm restart registrar

    #To preserve whitespace in echo commands...
    IFS='%'

    #haproxy
    for port in "${ports[@]}"; do
        hainstances="$hainstances        server electric-moray-$port 127.0.0.1:$port check inter 10s slowstart 10s error-limit 3 on-error mark-down\n"
    done

    sed -e "s#@@ELECTRIC-MORAY_INSTANCES@@#$hainstances#g" \
        $SVC_ROOT/etc/haproxy.cfg.in > $SVC_ROOT/etc/haproxy.cfg || \
        fatal "could not process $src to $dest"

    svccfg import $SVC_ROOT/smf/manifests/haproxy.xml || \
        fatal "unable to import haproxy"
    svcadm enable "manta/haproxy" || fatal "unable to start haproxy"

    #electric-moray instances
    local electric_moray_xml_in=$SVC_ROOT/smf/manifests/electric-moray.xml.in
    for (( i=1; i<=$ELECTRIC_MORAY_INSTANCES; i++ )); do
        local port=${ports[$i]}
        local kang=${kangs[$i]}
        local status=${statuses[$i]}
        local electric_moray_instance="electric-moray-$port"
        local electric_moray_xml_out=$SVC_ROOT/smf/manifests/electric-moray-$port.xml
        sed -e "s#@@ELECTRIC-MORAY_PORT@@#$port#g" \
            -e "s#@@KANG_PORT@@#$kang#g" \
            -e "s#@@STATUS_PORT@@#$status#g" \
            -e "s#@@ELECTRIC-MORAY_INSTANCE_NAME@@#$electric_moray_instance#g" \
            $electric_moray_xml_in  > $electric_moray_xml_out || \
            fatal "could not process $electric_moray_xml_in to $electric_moray_xml_out"

        svccfg import $electric_moray_xml_out || \
            fatal "unable to import $electric_moray_instance: $electric_moray_xml_out"
        svcadm enable "$electric_moray_instance" || \
            fatal "unable to start $electric_moray_instance"
    done

    #
    # We join the metric ports in a comma-separated list, then add this list as
    # metricPorts mdata to allow scraping by cmon-agent.
    #
    # The metricPorts values are derived from the electric-moray service's
    # "SIZE" SAPI metadata. We don't need to worry about keeping the metricPorts
    # updated if this variable changes, because such a change does not affect
    # already-provisioned zones. This is because electric-moray zones pull the
    # "SIZE" variable from /var/tmp/metadata.json, which is only written once,
    # when the zone is provisioned -- it is not managed by config-agent.
    #
    mdata-put metricPorts $(IFS=','; echo "${kangs[*]}")

    unset IFS
}


# Mainline

echo "Modifying syslog.conf"
manta_hack_syslog_conf

echo "Running common setup scripts"
manta_common_presetup

echo "Adding local manifest directories"
manta_add_manifest_dir "/opt/smartdc/electric-moray"

manta_common2_setup "electric-moray" 0

manta_setup_determine_instances

echo "Setting up leveldb"
manta_setup_leveldb_hash_ring

echo "Setting up e-moray"
manta_setup_electric_moray

manta_common2_setup_log_rotation "electric-moray"
manta_common2_setup_end

exit 0
