#!/bin/sh
while wait
do
    sleep 30 &
    /usr/bin/airplanes-feeder --quiet --net --net-only \
        --db-file=none --max-range 450 \
        --net-beast-reduce-interval 0.5 \
        --net-connector feed.airplanes.live,30004,beast_reduce_plus_out,feed2.airplanes.live,64004 \
        --net-connector 127.0.0.1,30005,beast_in \
        --net-ro-interval 0.2 \
        --json-location-accuracy 2 --write-json /run/airplanes-feed \
        --lat $LATITUDE --lon $LONGITUDE
done