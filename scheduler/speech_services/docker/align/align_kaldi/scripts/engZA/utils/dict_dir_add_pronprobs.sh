#!/bin/bash

# Apache 2.0.
# Copyright  2014  Johns Hopkins University (author: Daniel Povey)
#            2014  Guoguo Chen


. ./path.sh || exit 1;

# begin configuration
max_normalize=true
# end configuration

. utils/parse_options.sh || exit 1;

set -e

if [[ $# -ne 3 && $# -ne 4 ]]; then
  echo "Usage: $0 [options] <input-dict-dir> <input-pron-counts> \\"
  echo "                    [input-sil-counts] <output-dict-dir>"
  echo " e.g.: $0 data/local/dict exp/tri3/pron_counts_nowb.txt \\"
  echo "                    exp/tri3/sil_counts_nowb.txt data/local/dict_prons"
  echo " e.g.: $0 data/local/dict exp/tri3/pron_counts_nowb.txt \\"
  echo "                    data/local/dict_prons"
  echo ""
  echo "This script takes pronunciation counts, e.g. generated by aligning your training"
  echo "data and getting the prons using steps/get_prons.sh, and creates a modified"
  echo "dictionary directory with pronunciation probabilities. If the [input-sil-counts]"
  echo "parameter is provided, it will also include silprobs in the generated lexicon."
  echo "Options:"
  echo "   --max-normalize   (true|false)             # default true.  If true,"
  echo "                                              # divide each pron-prob by the"
  echo "                                              # most likely pron-prob per word."
  exit 1;
fi

if [ $# -eq 3 ]; then
  srcdir=$1
  pron_counts=$2
  dir=$3
elif [ $# -eq 4 ]; then
  srcdir=$1
  pron_counts=$2
  sil_counts=$3
  dir=$4
fi

if [ ! -s $pron_counts ]; then
  echo "$0: expected file $pron_counts to exist";
fi

mkdir -p $dir || exit 1;
utils/validate_dict_dir.pl $srcdir;

if [ -f $srcdir/lexicon.txt ]; then
  src_lex=$srcdir/lexicon.txt
  perl -ane 'print join(" ", split(" ", $_)) . "\n";' <$src_lex >$dir/lexicon.txt
elif [ -f $srcdir/lexiconp.txt ]; then
  echo "$0: removing the pron-probs from $srcdir/lexiconp.txt to create $dir/lexicon.txt"
  # the Perl command below normalizes the spaces (avoid double space).
  src_lex=$srcdir/lexiconp.txt
  awk '{$2 = ""; print $0;}' <$srcdir/lexiconp.txt | perl -ane 'print join(" ", split(" " ,$_)) . "\n";'  >$dir/lexicon.txt || exit 1;
fi


# the cat and awk commands below are implementing add-one smoothing.
cat <(awk '{print 1, $0;}' <$dir/lexicon.txt) $pron_counts | \
  awk '{ count = $1; $1 = ""; word_count[$2] += count; pron_count[$0] += count; pron2word[$0] = $2; }
       END{ for (p in pron_count) { word = pron2word[p]; num = pron_count[p]; den = word_count[word]; 
          print num / den, p } } ' | \
    awk '{ word = $2; $2 = $1; $1 = word; print; }' | grep -v '^<eps>' | sort >$dir/lexiconp.txt


n_old=$(wc -l <$dir/lexicon.txt)
n_new=$(wc -l <$dir/lexiconp.txt)

if [ "$n_old" != "$n_new" ]; then
  echo "$0: number of lines differs from $dir/lexicon.txt $n_old vs $dir/lexiconp.txt $n_new"
  echo "Probably something went wrong (e.g. input prons were generated from a different lexicon"
  echo "than $srcdir, or you used pron_counts.txt when you should have used pron_counts_nowb.txt"
  echo "or something else.  Make sure the prons in $src_lex $pron_counts look"
  echo "the same."
  exit 1;
fi

if $max_normalize; then
  echo "$0: normalizing pronprobs so maximum is 1 for each word."
  cat $dir/lexiconp.txt | awk '{if ($2 > max[$1]) { max[$1] = $2; }} END{for (w in max) { print w, max[w]; }}' > $dir/maxp.txt
  
  awk -v maxf=$dir/maxp.txt  'BEGIN{ while (getline <maxf) { max[$1] = $2; }} { $2 = $2 / max[$1]; print }' <$dir/lexiconp.txt > $dir/lexicon_tmp.txt || exit 1;
  if ! [ $(wc -l  <$dir/lexicon_tmp.txt)  -eq $(wc -l  <$dir/lexiconp.txt) ]; then
    echo "$0: error max-normalizing pron-probs"
    exit 1;
  fi
  mv $dir/lexicon_tmp.txt $dir/lexiconp.txt
  rm $dir/maxp.txt
fi


# Create $dir/lexiconp_silprob.txt and $dir/silprob.txt if silence counts file
# exists. The format of $dir/lexiconp_silprob.txt is:
# word pron-prob sil-before-prob sil-after-prob pron...
if [ -n "$sil_counts" ]; then
  if [ ! -s "$sil_counts" ]; then
    echo "$0: expected file $sil_counts to exist and not empty" && exit 1;
  fi
  cat $sil_counts | perl -e '
    # Load silence counts
    %sil_wpron = (); %nonsil_wpron = (); %wpron_sil = (); %wpron_nonsil = ();
    $sil_count = 0; $nonsil_count = 0;
    while (<STDIN>) {
      chomp; @col = split; @col >= 5 || die "'$0': bad line \"$_\"\n";
      $wpron = join(" ", @col[4..scalar(@col)-1]);
      ($sil_wpron{$wpron}, $nonsil_wpron{$wpron},
       $wpron_sil{$wpron}, $wpron_nonsil{$wpron}) = @col[0..3];
      $sil_count += $sil_wpron{$wpron}; $nonsil_count += $nonsil_wpron{$wpron};
    }

    # Open files.
    ($lexiconp, $lexiconp_silprob, $silprob) = @ARGV;
    open(LP, "<$lexiconp") || die "'$0': fail to open $lexiconp\n";
    open(SP, ">$silprob") || die "'$0': fail to open $silprob\n";
    open(LPSP, ">$lexiconp_silprob") ||
      die "'$0': fail to open $lexiconp_silprob\n";

    # Create silprob.txt
    $BOS_sil_prob = sprintf("%.2f",
      $wpron_sil{"<s>"} / ($wpron_sil{"<s>"} + $wpron_nonsil{"<s>"}));
    $sil_EOS_prob = sprintf("%.2f",
      $sil_wpron{"</s>"} / ($sil_wpron{"</s>"} + $nonsil_wpron{"</s>"}));

    if ($BOS_sil_prob == "1.00") {
      $sil_after_prob = "0.99";
    }
    if ($sil_EOS_prob == "1.00") {
      $sil_EOS_prob = "0.99";
    }

    $sil_prob = sprintf("%.2f", $sil_count / ($sil_count + $nonsil_count));
    print SP "<s> $BOS_sil_prob\n</s> $sil_EOS_prob\noverall $sil_prob\n";

    # Create lexiconp_silprob.txt
    while (<LP>) {
      chomp; @col = split; @col >= 3 || die "'$0': bad line \"$_\"\n";
      $word = shift @col; $pron_prob = shift @col; $pron = join(" ", @col);
      unshift(@col, $word); $wpron = join(" ", @col);
      # ========================================================================
      # Smoothing happens here.
      $constant = 2; # The constant here is arbitrary for now; wll change.
      $wpron_sil_count = $wpron_sil{$wpron} + $sil_prob * $constant;
      $wpron_nonsil_count = $wpron_nonsil{$wpron} + (1 - $sil_prob) * $constant;
      $sil_wpron_count = $sil_wpron{$wpron} + $sil_prob * $constant;
      $nonsil_wpron_count = $nonsil_wpron{$wpron} + (1 - $sil_prob) * $constant;
      # ========================================================================

      $sil_after_prob = sprintf("%.2f",
        $wpron_sil_count / ($wpron_sil_count + $wpron_nonsil_count));
      $sil_before_prob = sprintf("%.2f",
        $sil_wpron_count / ($sil_wpron_count + $nonsil_wpron_count));

      if ($sil_after_prob == "0.00") {
        $sil_after_prob = "0.01";
      }
      if ($sil_after_prob == "1.00") {
        $sil_after_prob = "0.99";
      }
      if ($sil_before_prob == "0.00") {
        $sil_before_prob = "0.01";
      }
      if ($sil_before_prob == "1.00") {
        $sil_before_prob = "0.99";
      }

      print LPSP "$word $pron_prob $sil_before_prob $sil_after_prob $pron\n";
    }' $dir/lexiconp.txt $dir/lexiconp_silprob.txt $dir/silprob.txt
fi


# now regenerate lexicon.txt from lexiconp.txt, to make sure the lines are
# in the same order. 
cat $dir/lexiconp.txt | awk '{$2 = ""; print;}' | sed 's/  / /g' >$dir/lexicon.txt

# add mandatory files.
for f in silence_phones.txt nonsilence_phones.txt; do
  if [ ! -f $srcdir/$f ]; then
    echo "$0: expected $srcdir/$f to exist."
    exit 1;
  fi
  cp $srcdir/$f $dir/ || exit 1;
done


# add optional files (at least, I think these are optional; would have to check the docs).
for f in optional_silence.txt extra_questions.txt; do
  if [ -f $dir/$f ]; then
    rm $dir/$f
  fi
  if [ -f $srcdir/$f ]; then
    cp $srcdir/$f $dir || exit 1;
  fi
done


echo "$0: produced dictionary directory with probabilities in $dir/"
echo "$0: validating $dir .."
sleep 1
utils/validate_dict_dir.pl $dir || exit 1;


echo "Some low-probability prons include: "
echo "# sort -k2,2 -n $dir/lexiconp.txt  | head -n 8"

sort -k2,2 -n $dir/lexiconp.txt  | head -n 8

exit 0
