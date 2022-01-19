#!/usr/bin/env bash
# Copyright   2020   Johns Hopkins University (Author: Desh Raj)
# Apache 2.0.
#
# Altered by Sebastian Klinger (Technische Hochschule Georg Simon Ohm)
# to include eval2000 as evaluation set.
#
# This recipe performs diarization for the mix-headset data in the
# AMI dataset. The x-vector extractor we use is trained on VoxCeleb v2 
# corpus with simulated RIRs. We use oracle SAD in this recipe.
# This recipe demonstrates the following:
# 1. Diarization using x-vector and clustering (AHC, VBx, spectral)
# 2. Training an overlap detector (using annotations) and corresponding
# inference on full recordings.

# We do not provide training script for an x-vector extractor. You
# can download a pretrained extractor from:
# http://kaldi-asr.org/models/12/0012_diarization_v1.tar.gz
# and extract it.

. ./cmd.sh
. ./path.sh
set -euo pipefail
mfccdir=`pwd`/mfcc


# only these stages (e.g. stages="1 5 9 10")
stages=""
# if $stages are empty, than from stage to last stage
from_stage=0
last_stage=10

overlap_stage=0
diarizer_stage=0
nj=50
decode_nj=15

model_dir=exp/xvector_nnet_1a

train_set=train # ami
test_sets=eval2000
#test_sets="dev test" # ami

diarizer_type=spectral  # must be one of (ahc, spectral, vbx)

AMI_DIR=/mnt/md0/data/ami/amicorpus/amicorpus
eval2000_dir=/mnt/md0/data/eval2000/hub5e_00
eval2000_transcripts_dir=/mnt/md0/data/eval2000-transcripts/2000_hub5_eng_eval_tr

. utils/parse_options.sh

stage=0

if [ "${#stages}" -eq 0 ]; then
  if [ ${from_stage} -ge 0 ]; then
    echo "$0: No stage array was delivered. Using stage to determine array."
    stages=($(seq ${from_stage} 1 ${last_stage}))
  else
    echo "$0: No stage information was provided."
    echo '$0: Use e.g. --from_stage 0 or --stages "0 1 4". Exiting.'
    exit 1
  fi  
  echo "$0: Will execute following stages: ${stages[@]}"
fi

# stage 0
# Prepare AMI training data directories. 
if [[ " ${stages[*]} " =~ " ${stage} " ]]; then
  # Download the data split and references from BUT's AMI setup
  if ! [ -d AMI-diarization-setup ]; then
    git clone https://github.com/BUTSpeechFIT/AMI-diarization-setup
  fi

  for dataset in train; do
    echo "$0: Preparing AMI $dataset set."
    mkdir -p data/$dataset
    # Prepare wav.scp and segments file from meeting lists and oracle SAD
    # labels, and concatenate all reference RTTMs into one file.
    local/prepare_data.py --sad-labels-dir AMI-diarization-setup/only_words/labs/${dataset} \
      AMI-diarization-setup/lists/${dataset}.meetings.txt \
      $AMI_DIR data/$dataset
    cat AMI-diarization-setup/only_words/rttms/${dataset}/*.rttm \
      > data/${dataset}/rttm.annotation

    awk '{print $1,$2}' data/$dataset/segments > data/$dataset/utt2spk
    utils/utt2spk_to_spk2utt.pl data/$dataset/utt2spk > data/$dataset/spk2utt
    utils/fix_data_dir.sh data/$dataset
  done
fi
((stage+=1))

# stage 1
# Prepare eval2000 test set
if [[ " ${stages[*]} " =~ " ${stage} " ]]; then
  echo "$0: Preparing eval2000 test set."
  local_eval2000_dir=data/eval2000
  if ! validate_data_dir.sh --no-text --no-feats $local_eval2000_dir; then
      local/eval2000_data_prep.sh $eval2000_dir $eval2000_transcripts_dir
      utils/fix_data_dir.sh $local_eval2000_dir
  fi

  # create rttm.annotation for eval2000
  steps/segmentation/convert_utt2spk_and_segments_to_rttm.py \
    data/eval2000/utt2spk data/eval2000/segments \
    data/eval2000/rttm.annotation
fi
((stage+=1))

# stage 2
# Feature extraction only for train set
if [[ " ${stages[*]} " =~ " ${stage} " ]]; then
  echo "$0: Feature extraction for train set."
  for dataset in $train_set; do
    steps/make_mfcc.sh --mfcc-config conf/mfcc_hires.conf --nj $nj --cmd "$train_cmd" data/$dataset
    steps/compute_cmvn_stats.sh data/$dataset
    utils/fix_data_dir.sh data/$dataset
  done
fi
((stage+=1))

# stage 3
# Feature extraction only for test set
if [[ " ${stages[*]} " =~ " ${stage} " ]]; then
  echo "$0: Feature extraction for test set."
  for dataset in $test_sets; do
    steps/make_mfcc.sh --mfcc-config conf/mfcc_hires.conf --nj $nj --cmd "$train_cmd" data/$dataset
    steps/compute_cmvn_stats.sh data/$dataset
    utils/fix_data_dir.sh data/$dataset
  done
fi
((stage+=1))

# stage 4
if [[ " ${stages[*]} " =~ " ${stage} " ]]; then
  echo "$0: Preparing AMI training data to train PLDA model."
  local/nnet3/xvector/prepare_feats.sh --nj $nj --cmd "$train_cmd" \
    data/train data/plda_train exp/plda_train_cmn
fi
((stage+=1))

# stage 5
if [[ " ${stages[*]} " =~ " ${stage} " ]]; then
  echo "$0: Extracting x-vector for PLDA training data."
    
  # Download and unpack net for xvector extraction
  if [ ! -d exp/xvector_nnet_1a ]; then
      wget http://kaldi-asr.org/models/12/0012_diarization_v1.tar.gz
      tar zxf 0012_diarization_v1.tar.gz
      cp -R 0012_diarization_v1/exp/xvector_nnet_1a exp/
  fi

  utils/fix_data_dir.sh data/plda_train
  # from kaldi/egs/callhome_diarization/v1/diarization/nnet3/xvector/
  local/nnet3/xvector/extract_xvectors.sh --cmd "$train_cmd" \
    --nj $nj --window 3.0 --period 10.0 --min-segment 1.5 --apply-cmn false \
    --hard-min true $model_dir \
    data/plda_train $model_dir/xvectors_plda_train
fi
((stage+=1))

# stage 6
# Train PLDA models
if [[ " ${stages[*]} " =~ " ${stage} " ]]; then
  echo "$0: Training PLDA model."
  # Compute the mean vector for centering the evaluation xvectors.
  $train_cmd $model_dir/xvectors_plda_train/log/compute_mean.log \
    ivector-mean scp:$model_dir/xvectors_plda_train/xvector.scp \
    $model_dir/xvectors_plda_train/mean.vec || exit 1;

  # Train the PLDA model.
  $train_cmd $model_dir/xvectors_plda_train/log/plda.log \
    ivector-compute-plda ark:$model_dir/xvectors_plda_train/spk2utt \
    "ark:ivector-subtract-global-mean scp:$model_dir/xvectors_plda_train/xvector.scp ark:- |\
     transform-vec $model_dir/xvectors_plda_train/transform.mat ark:- ark:- |\
      ivector-normalize-length ark:-  ark:- |" \
    $model_dir/xvectors_plda_train/plda || exit 1;
  
  cp $model_dir/xvectors_plda_train/plda $model_dir/
  cp $model_dir/xvectors_plda_train/transform.mat $model_dir/
  cp $model_dir/xvectors_plda_train/mean.vec $model_dir/
  echo "$0: Training PLDA model done."
fi
((stage+=1))

# stage 7
# Diarization
if [[ " ${stages[*]} " =~ " ${stage} " ]]; then
  echo "$0: Diarization started."
  for datadir in ${test_sets}; do
    ref_rttm=data/${datadir}/rttm.annotation

    diarize_nj=$(wc -l < "data/$datadir/wav.scp")
    nj=$((decode_nj>diarize_nj ? diarize_nj : decode_nj))
    local/diarize_${diarizer_type}.sh --nj $nj --cmd "$train_cmd" --stage $diarizer_stage \
      $model_dir data/${datadir} exp/${datadir}_diarization_${diarizer_type}

    # Evaluate RTTM using md-eval.pl
    rttm_affix=
    if [ $diarizer_type == "vbx" ]; then
      rttm_affix=".vb"
    fi
    md-eval.pl -r $ref_rttm -s exp/${datadir}_diarization_${diarizer_type}/rttm${rttm_affix}    
  done
  echo "$0: Diarization done."
fi
((stage+=1))

# stage 8
# These stages demonstrate how to perform training and inference
# for an overlap detector.
if [[ " ${stages[*]} " =~ " ${stage} " ]]; then
  echo "$0: Training overlap detector."
  local/train_overlap_detector.sh --stage $overlap_stage --test-sets "$test_sets" $AMI_DIR
  echo "$0: Training overlap detector done."
fi
((stage+=1))

# stage 9
# Overlap Detection
overlap_affix=1a
if [[ " ${stages[*]} " =~ " ${stage} " ]]; then
  for dataset in $test_sets; do
    echo "$0: Performing overlap detection on ${dataset}."
    local/detect_overlaps.sh --convert_data_dir_to_whole true \
      --output-scale "1 2 1" \
      data/${dataset} \
      exp/overlap_$overlap_affix/tdnn_lstm_1a \
      exp/overlap_$overlap_affix/$dataset
  done
  echo "$0: Overlap detection on ${dataset} done."
fi
((stage+=1))

# stage 10
# Evaluation
if [[ " ${stages[*]} " =~ " ${stage} " ]]; then
  for dataset in $test_sets; do
    echo "$0: Evaluating output for ${dataset}."
    steps/overlap/get_overlap_segments.py data/$dataset/rttm.annotation | grep "overlap" |\
      md-eval.pl -r - -s exp/overlap_$overlap_affix/$dataset/rttm_overlap |\
      awk 'or(/MISSED SPEAKER TIME/,/FALARM SPEAKER TIME/)'
  done
  echo "$0: Evaluating output for ${dataset} done."
fi
((stage+=1))

