#!/bin/bash

Greeting=$1
Target=$2

FULL_GREETING="${Greeting} ${Target}. My name is ${_tapisJobOwner}"
echo "$FULL_GREETING"

echo $FULL_GREETING > $_tapisExecSystemOutputDir/out.txt