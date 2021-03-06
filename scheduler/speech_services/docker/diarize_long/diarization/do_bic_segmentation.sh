#!/bin/bash
set -eu

if [ $# -ne "3" ] && [ $# -ne "5" ]; then
  echo "Usage: $0 <in:fn-wav> <out:fn-seg> <out:dir-out> [<initial-seg> <label>]"
  echo "  fn-wav      - audio file to be segmented using BIC"
  echo "  fn-seg      - file where segmentation info should be saved to"
  echo "  dir-out     - directory within which all output created"
  echo "  initial-seg - an initial segmentation to work from"
  echo "  label       - the label to use within the initial segmentation"
  echo "e.g.: $0 abc.wav abc.seg /tmp speech_sil.seg:speech"
  echo ""
  echo "NB: If dir-out/fn-wav and dir-out/fn-mfcc exists, this script will use it"
  exit 1;
fi

# -----------------------------------------------------------------------------
echo "$0 $@"
dir_script="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

wav=$1
seg=$2
dir_out=$3

init_seg=0
init_seg_fn=""
init_seg_lab=""

if [ $# -eq "5" ]; then
  init_seg=1
  init_seg_fn=$4
  init_seg_lab=$5
fi

dir_work=$dir_out
mkdir -p $dir_work # just to be safe

# -----------------------------------------------------------------------------

# Check required scripts / software

binaries=( sox sfbcep sbic soxi ) 

exit_status=0
missing=""
for bin in "${binaries[@]}"; do
  type -p $bin &> /dev/null
  if [ $? -ne 0 ]; then
    missing="$missing [$bin]"
    exit_status=2
  fi
done

if [ $exit_status = 2 ]; then
  echo "ERROR: Binaries/scripts missing! $missing" 1>&2
  exit $exit_status
else
  echo "Info: All required software present"
fi

# -----------------------------------------------------------------------------

# Get audio file information

bn=`echo $wav | awk -F '/' '{print $NF}' | sed "s/\.[^\.]\+$//g"` || ( echo "ERROR: basename failed!" 1>&2; exit 2 )
sf=`soxi $wav | grep "Sample Rate" | awk '{print $NF}'` || ( echo "ERROR: sox information $wav failed!" 1>&2; exit 2 )

# -----------------------------------------------------------------------------

# Convert the audio to wav file (in case other format)

if [ ! -e "$dir_work/${bn}.wav" ]; then
  echo "Info: Converting '$wav' to wav file -> $dir_work/${bn}.wav"
  sox $wav $dir_work/${bn}.wav || ( echo "ERROR: sox converting wav failed!" 1>&2; exit 2 )
else
  echo "Info: using $dir_work/${bn}.wav"
  soxi $wav || ( echo "ERROR: soxi $wav failed!" 1>&2; exit 2 )
  soxi $dir_work/${bn}.wav || ( echo "ERROR: soxi $dir_work/${bn}.wav failed!" 1>&2; exit 2 )
fi

if [ ! -e "$dir_work/${bn}.mfcc" ]; then
  echo "Info: Extracting features"
  sfbcep -f ${sf} --mel --num-filter=40 --num-cep=20 \
    $dir_work/${bn}.wav $dir_work/${bn}.mfcc || ( echo "ERROR: sfbcep failed!" 1>&2; exit 2 )
else
  echo "Info: using $dir_work/${bn}.mfcc"
fi

if [ $init_seg -eq 0 ]; then
  sbic $dir_work/${bn}.mfcc $dir_work/${bn}.sbic.seg || ( echo "ERROR: sbic failed!" 1>&2; exit 2 )
else
  sbic --segmentation=${init_seg_fn} \
    --label=${init_seg_lab} $dir_work/${bn}.mfcc $dir_work/${bn}.sbic.seg  || ( echo "ERROR: sbic with segmentation failed!" 1>&2; exit 2 )
fi

if ! cmp $dir_work/${bn}.sbic.seg $seg
then
  cp -v $dir_work/${bn}.sbic.seg $seg
else
  wc -l $seg
fi

# -----------------------------------------------------------------------------

echo "Info: Done sbic segmentation!"
exit 0
