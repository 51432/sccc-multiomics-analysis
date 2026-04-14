#!/usr/bin/env bash

qsub() {
  legacy_qsub "$@"
}

export -f qsub
