#!/bin/bash

WEBSOKIFY_PORT=${1:-6080}
NoVNC_DIR=${2:-/path/to/noVNC}
NOVNC_TOKEN_DIR=${3:-/path/to/token}

websockify -D --web $NoVNC_DIR $WEBSOKIFY_PORT --token-plugin TokenFileName --token-source $NOVNC_TOKEN_DIR