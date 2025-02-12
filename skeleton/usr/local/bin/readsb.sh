#!/bin/bash

if [[ "$DUMP1090" == "no" ]]; then
    RECEIVER_OPTIONS="--net-only"
fi

if [[ "$MODEAC" == "yes" ]]; then
    DECODER_OPTIONS=$DECODER_OPTIONS" --modeac"
fi

if [[ "$AUTOGAIN" == "yes" ]]; then
    $GAIN_OPT=" --gain=auto"
else
    $GAIN_OPT=" --gain=$GAIN"
fi



exec /usr/bin/readsb \
    --net-api-port 30152 \
    --net-json-port 30154 \
    --write-prom /run/readsb/stats.prom \
     $GAIN_OPT \
    --lat $LATITUDE \
    --lon $LONGITUDE \
    $RECEIVER_OPTIONS \
    $DECODER_OPTIONS \
    $NET_OPTIONS \
    $JSON_OPTIONS \
    --write-json /run/readsb --quiet
