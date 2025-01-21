#!/bin/bash

: "${MAAS_PATH:="../maas"}"

cd "${MAAS_PATH}" || exit


mkdir -p artifacts

make all

cd charts || exit
for i in $(find  . -maxdepth 1  -name "*.tgz"  -print | sed -e 's/\-[0-9.]*\.tgz//'| cut -d / -f 2 | sort)
do
    find . -name "$i-[0-9.]*.tgz" -print -exec cp -av {} "../artifacts/$i.tgz" \;
done
