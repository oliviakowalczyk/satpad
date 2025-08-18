#!/bin/bash
####dcm2bids_loop.sh####
# Loops dcm2bids through all subjects present in sourcedata directory; to execute: sh dcm2bids_loop.sh
# Created: Olivia Kowalczyk 23/10/2022
###################

dir=/root/dir
cd ${dir}

for sub_dir in `ls ${dir}/sourcedata`; do
	sub=$(basename "$dir")

	dcm2bids -d sourcedata/${sub_dir} -p ${sub} -s cervical -c code/dcm2bids_config.json -o data/

done
