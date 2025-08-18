#!/bin/bash

# Following taken (almost) entirely from Rob Barry's use of AFNI' 3dWarpDrive in Neptune (MATLAB tool)
# 2022/05/09

if [ $# -ne 3 ] ; then
	echo "Usage:" $(basename $0) "<input4D> <target> <mask>"
	exit
fi

fbase=$(basename $1 .nii.gz)
numslices=$(fslval $1 dim3)
oneless=$(echo "$numslices - 1" | bc)
tpoints=$(fslval $1 dim4)
endpoint=$(echo "$tpoints - 1" | bc)

# dimensions of onepix
xdim=$(fslval $1 dim1)
ydim=$(fslval $1 dim2)
xpixdim=$(fslval $1 pixdim1)
ypixdim=$(fslval $1 pixdim2)
zpixdim=$(fslval $1 pixdim3)
tr=$(fslval $1 pixdim4)

outxpixdim=$(awk -v v1="$xdim" -v v2="$xpixdim" 'BEGIN { printf "%6.5f", v1 * v2 }')
outypixdim=$(awk -v v1="$ydim" -v v2="$ypixdim" 'BEGIN { printf "%6.5f", v1 * v2 }')
outzpixdim=$zpixdim

parfix="-parfix 3 0 -parfix 4 0 -parfix 5 0 -parfix 6 0 -parfix 7 1 -parfix 8 1 -parfix 9 1 -parfix 10 0 -parfix 11 0 -parfix 12 0"

# nasty
if [ -d mocotmp ] ; then
	rm -rf mocotmp
fi
mkdir mocotmp

# create onepix for later use
$FSLDIR/bin/fslcreatehd 1 1 1 1 $outxpixdim $outypixdim $outzpixdim $tr 0 0 0 16 mocotmp/onepix

# split according to slice
fslsplit $1 mocotmp/slice -z
fslsplit $2 mocotmp/target -z
fslsplit $3 mocotmp/mask -z


for pass in one two ; do
	for i in $(seq 0 ${oneless}) ; do
		slicepad=$(zeropad $i 4)
		echo "PASS $pass"
		if [ "${pass}" == "one" ] ; then
			baseim=target${slicepad}.nii.gz
		else
			baseim=target${slicepad}_MC_tmean.nii.gz
		fi

		#3dWarpDrive -affine_general $parfix -quintic -final quintic \
		        -base mocotmp/$baseim \
		        -prefix mocotmp/slice${slicepad}_MCnofilt.nii.gz \
		        -weight mocotmp/mask${slicepad}.nii.gz \
		        -1Dfile mocotmp/slice${slicepad}_MC_params.txt \
		        -1Dmatrix_save mocotmp/slice${slicepad}_MC_xform.aff12.1D \
					mocotmp/slice${slicepad}.nii.gz
		
		3dWarpDrive -affine_general $parfix -NN \
		        -base mocotmp/$baseim \
		        -prefix mocotmp/slice${slicepad}_MCnofilt.nii.gz \
		        -weight mocotmp/mask${slicepad}.nii.gz \
		        -1Dfile mocotmp/slice${slicepad}_MC_params.txt \
		        -1Dmatrix_save mocotmp/slice${slicepad}_MC_xform.aff12.1D \
					mocotmp/slice${slicepad}.nii.gz

		# if on first pass create new mean image to register to
		if [ "${pass}" == "one" ] ; then
			fslmaths mocotmp/slice${slicepad}_MCnofilt -Tmean mocotmp/target${slicepad}_MC_tmean
	        rm mocotmp/slice${slicepad}_MCnofilt.nii.gz
	    else # we've completed second pass, now just need to create per slice motion regressor
	        for dim in x y ; do
	        	for t in $(seq 0 ${endpoint}) ; do
	        		timeline=$(echo "$t + 4" | bc)
	        		zp_t=$(zeropad $t 4)
	        		if [ "${dim}" == "x" ] ; then
	        			val=$(cat mocotmp/slice${slicepad}_MC_params.txt | awk -v tp="${timeline}" '{if(NR==tp){print $1}}')
	        		else
	        			val=$(cat mocotmp/slice${slicepad}_MC_params.txt | awk -v tp="${timeline}" '{if(NR==tp){print $2}}')
	        		fi
	        		fslmaths mocotmp/onepix -add $val mocotmp/${dim}_${slicepad}_${zp_t}
	        	done
	        	$FSLDIR/bin/fslmerge -tr mocotmp/${dim}_${slicepad} mocotmp/${dim}_${slicepad}_????.nii.gz $tr
	        done
        fi

        
	done
	
done

fslmerge -z ${fbase}_MCnofilt mocotmp/slice????_MCnofilt.nii.gz
fslmerge -z ${fbase}_MCnofilt_x_params mocotmp/x_????.nii.gz
fslmerge -z ${fbase}_MCnofilt_y_params mocotmp/y_????.nii.gz
fslmaths ${fbase}_MCnofilt -Tmean ${fbase}_MCnofilt_tmean

mkdir moco_params
cp mocotmp/*MC_params.txt moco_params

# tidy up (bit brutal)
rm -rf mocotmp

