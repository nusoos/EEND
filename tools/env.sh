# Task-independent environmental variables
export KALDI_ROOT=`pwd`/../../../tools/kaldi
[ -f $KALDI_ROOT/tools/env.sh ] && . $KALDI_ROOT/tools/env.sh
export PATH=$PWD/utils/:$KALDI_ROOT/tools/openfst/bin:$KALDI_ROOT/tools/sph2pipe_v2.5:$KALDI_ROOT/tools/sctk/bin:$PWD:$PATH
[ ! -f $KALDI_ROOT/tools/config/common_path.sh ] && echo >&2 "The standard file $KALDI_ROOT/tools/config/common_path.sh is not present -> Exit!" && exit 1
. $KALDI_ROOT/tools/config/common_path.sh
export PATH=../../../tools/miniconda3/envs/eend/bin:$PATH
export PATH=../../../eend/bin:../../../utils:$PATH
export PYTHONPATH=../../..:$PYTHONPATH
# cuda runtime
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:
