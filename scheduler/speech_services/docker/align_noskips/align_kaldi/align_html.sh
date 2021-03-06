#!/bin/bash

set -e

WHERE="$HOME/align/align_kaldi"
scratch=

# Final cleanup code
#function cleanup {
#  EXIT_STATUS=$?
#  if [ "$?" -ne 0 ]; then
#    echo "ERROR: $?"
#  fi
#  exit $EXIT_STATUS 
#}
#trap cleanup EXIT;

# Parse arguments
if [ $# -ne 4 ]; then
    echo "$0 in_audio_file in_html system out_html"
    exit 1
fi

echo "$0 $@"
audio_file=$1
in_html=$2
system=$3
out_html=$4

# Create workspace
echo "Creating workspace"
scratch=`mktemp -p . -d`
scratch=`readlink -f $scratch`
echo $scratch

# Decode OGG file
echo "Decoding ogg: $audio_file"
oggdec -o $scratch/audio.wav $audio_file || ( echo "oggdec failed!" 1>&2; exit 2 )

# Determine number of channels
channels=`soxi $scratch/audio.wav | grep 'Channels' | awk -F ':' {'print $2'} | tr -d ' '`
if [ $channels -gt "1" ]; then
  echo "ERROR: Single channel audio supported only!" 1>&2
  exit 2
fi

# Fix sampling rate if needed
workname=`basename $audio_file`
base=`echo $workname | awk -F '.' {'$NF="";print $0'} | tr ' ' '.' | sed 's:\.$::g'`

# Determine audio sample rate
samprate=`soxi $scratch/audio.wav | grep 'Sample Rate' | awk -F ':' {'print $2'} | tr -d ' '`

# Determine model sample rate
modelrate=`echo $system | awk -F '_' {'print $NF'}`

if [ "$modelrate" != "$samprate" ]; then
  echo "WARNING: Audio and model sample rate mismatch: AM= $modelrate, AU= $samprate"
fi

# Resample
sox $scratch/audio.wav -t wav "$scratch/$base"."wav" rate $model_rate || ( echo "ERROR: sox rate conversion failed!" 1>&2; exit 2 )
audio_file="$scratch/$base"."wav"

$WHERE/kaldi_align_ckdoc.py --lang $system $audio_file $in_html $out_html

echo "Done... $out_html"
rm -r $scratch

exit 0

