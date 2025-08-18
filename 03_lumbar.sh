#!/bin/bash

moco () {
	data_basename=$(basename ${2} .nii.gz)

	cd ${1}
	
	if [ -e "${data_basename}_MCnofilt_tmean.nii.gz" ]; then
        echo "${data_basename}_MCnofilt_tmean.nii.gz already exists, skipping."
    else
		echo "Prepping your data for tSNR calculation.Your input data is $2 in $1"
		
		# Create mask for motion correction
		fslmaths ${2} -Tmean ${data_basename}_tmean
		sct_get_centerline -i ${data_basename}_tmean.nii.gz -c t2s
		sct_create_mask -i ${data_basename}_tmean.nii.gz -p centerline,${data_basename}_tmean_centerline.nii.gz -size 10 -f gaussian -o ${data_basename}_tmean_mask_gaussian.nii.gz 
		
		# Run motion correction
		${4}/code/neptune_moco.sh ${data_basename} ${data_basename}_tmean ${data_basename}_tmean_mask_gaussian
		
		# Rename motion parameters
		mv moco_params moco_params_${3}
		
		# Create temporal mean of motion corrected data
		fslmaths ${data_basename}_MCnofilt -Tmean ${data_basename}_MCnofilt_tmean  
	fi
}

seg () {
	moco_basename=$(basename ${2} .nii.gz)
	anat_basename=$(basename ${3} .nii.gz)
	
	cd ${1}
	
	if [ -e "${moco_basename}_seg.nii.gz" ]; then
        echo "${moco_basename}_seg.nii.gz already exists, skipping."
    else
		echo "Your input data is $2 in $1"
		
		echo "Generating a mask of the cord on functional data"
		sct_deepseg -i ${moco_basename}_tmean.nii.gz -c t2star -task seg_sc_epi
	fi
	
	
	if [ -e "${anat_basename}_seg.nii.gz" ]; then
        echo "${anat_basename}_seg.nii.gz already exists, skipping."
    else
		echo "Your input data is $3 in $1"
		
		echo "Generating a mask of the cord using the T2w image with lumbar specific segmentation algorithm"
		sct_deepseg -task seg_lumbar_sc_t2w -i ${3}
		# inspect each mask and note down the coordinates of the conus - use the bottom-most voxel of the mask
	fi
}

labels () {
	# read subject, file, disc 17 and conus coordinates variables from a csv file - these coordinates need to manually identified
	while IFS="," read -r subject img disc17x disc17y disc17z conusx conusy conusz; do
		if [ "${3}" = "${subject}" ]; then
			if [ -e "${2}/sub-${subject}/${img}_labels.nii.gz" ]; then
				echo "${img}_labels.nii.gz already exists."
			else
				echo "sub: ${subject}"
				echo "img: ${img}"
				echo "Disc 17 coordinate: ${disc17x} ${disc17y} ${disc17z}"
				echo "Conus coordinates: ${conusx} ${conusy} ${conusz}"
				
				cd ${2}/lumbar/sub-${subject}
				
				echo "Labelling disc 17 and conus on T2w image"
				sct_label_utils -i ${img}.nii.gz -create ${disc17x},${disc17y},${disc17z},17:${conusx},${conusy},${conusz},99 -o ${img}_labels.nii.gz -qc ./
			fi
		fi
	done < ${1}/labels_lumbar.csv
}

reg () {
	moco_basename=$(basename ${2} .nii.gz)
	anat_basename=$(basename ${3} .nii.gz)
	
	cd ${1}
	
	# Before running this, add a label of 99 to the PAM50 template at the start of the cauda equinea/conus
    # sct_label_utils -i $SCT_DIR/data/PAM50/template/PAM50_label_disc.nii.gz -create-add 70,69,46,99 -o $SCT_DIR/data/PAM50/template/PAM50_label_disc.nii.gz
    
	if [ -e "${moco}_MCnofilt_tmean_reg.nii.gz" ]; then
        echo "${moco}_MCnofilt_tmean_reg.nii.gz already exists, skipping."
    else
		echo "Running template registration. Your input data is $2 in $1"
		
		echo "Register T2w image to template using conus label and modified template dics labels with conus added, parameters are tailored to lumbar cord reg"
		sct_register_to_template -i ${3} -s ${anat_basename}_seg.nii.gz -ldisc ${anat_basename}_labels.nii.gz -c t2 -ofolder reg/${4} -t ../../../PAM50/ -qc ./ \
		-param step=1,type=seg,algo=centermassrot:step=2,type=seg,algo=bsplinesyn,metric=MeanSquares,iter=3,slicewise=0:step=3,type=im,algo=syn,metric=CC,iter=3,slicewise=0
		
		echo "Registering T2w data to EPI"
		sct_register_multimodal \
		-i ${3} \
		-iseg ${anat_basename}_seg.nii.gz \
		-d ${moco_basename}_tmean.nii.gz \
		-dseg ${moco_basename}_tmean_bold_seg.nii.gz \
		-ofolder reg/${4} \
		-param step=1,type=seg,algo=centermass:step=2,type=im,algo=syn,metric=MI,slicewise=1,smooth=0,iter=3
		
		sct_warp_template -d ${3} -w reg/${4}/warp_template2anat.nii.gz -ofolder reg/${4}/
		sct_apply_transfo -i ${moco_basename}_tmean.nii.gz -d ${3} -w reg/${4}/warp_${moco_basename}_tmean2${anat_basename}.nii.gz -x nn
		mv ${moco_basename}_tmean_reg.nii.gz reg/${4}/${moco_basename}_tmean_reg_anat.nii.gz
		
		echo "Transforming T2w cord mask to EPI space"
		sct_apply_transfo \
		-i ${anat_basename}_seg.nii.gz \
		-d ${moco_basename}_tmean.nii.gz \
		-w reg/${4}/warp_${anat_basename}2${moco_basename}_tmean.nii.gz \
		-x nn

		echo "Creating new warp files"
		sct_concat_transfo \
		-d ${5}/data/PAM50/template/PAM50_t2.nii.gz \
		-w reg/${4}/warp_${moco_basename}_tmean2${anat_basename}.nii.gz reg/${4}/warp_anat2template.nii.gz \
		-o reg/${4}/warp_${moco_basename}_tmean2PAM50.nii.gz

		sct_concat_transfo \
		-d ${moco_basename}_tmean.nii.gz \
		-w reg/${4}/warp_template2anat.nii.gz reg/${4}/warp_${anat_basename}2${moco_basename}_tmean.nii.gz \
		-o reg/${4}/warp_PAM502${moco_basename}_tmean.nii.gz
		
		sct_apply_transfo -i ${moco_basename}_tmean.nii.gz -d ${5}/6.5/data/PAM50/template/PAM50_t2.nii.gz -w reg/${4}/warp_${moco_basename}_tmean2PAM50.nii.gz -x nn
		
		echo "Registering EPI data to PAM50 cord template via T2w registration warps"
		sct_register_multimodal \
		-i ${5}/data/PAM50/template/PAM50_t2s.nii.gz \
		-iseg ${5}/data/PAM50/template/PAM50_cord.nii.gz \
		-d ${moco_basename}_tmean.nii.gz \
		-dseg ${anat_basename}_seg_reg.nii.gz \
		-param step=1,type=seg,algo=slicereg,metric=MeanSquares:step=2,type=seg,algo=affine,metric=MeanSquares,gradStep=0.2:step=3,type=im,algo=syn,metric=CC,iter=5,shrink=2 \
		-initwarp reg/${4}/warp_PAM502${moco_basename}_tmean.nii.gz \
		-initwarpinv reg/${4}/warp_${moco_basename}_tmean2PAM50.nii.gz \
		-ofolder reg/${4}/
	fi
}

tsnr_cord () {
	moco_basename=$(basename ${2} .nii.gz)
	anat_basename=$(basename ${3} .nii.gz)
	
	cd ${1}
	
	if [ -e "tsnr/cord/${moco_basename}_tsnr_cord.txt" ]; then
        echo "${moco_basename}_tsnr_cord.txt already exists, skipping."
    else
		echo "Calculating whole-cord tSNR.Your input data is $2 in $1"
		fslmaths ${2} -Tstd ${moco_basename}_tstd
		fslmaths ${moco_basename}_tmean -div ${moco_basename}_tstd tsnr/${moco_basename}_tsnr
		fslstats tsnr/${moco_basename}_tsnr -k ${anat_basename}_seg_reg -M >> tsnr/cord/${moco_basename}_tsnr_cord.txt	
		
		sct_apply_transfo -i tsnr/${moco_basename}_tsnr.nii.gz -d ${5}/data/PAM50/template/PAM50_t2.nii.gz -w reg/${4}/warp_${moco_basename}_tmean2PAM50.nii.gz -x nn
		mv ${moco_basename}_tsnr_reg.nii.gz tsnr/
	fi
}

tsnr_segmental () {
	moco_basename=$(basename ${2} .nii.gz)
	
	cd ${1}
	
	if [ -e "tsnr/segmental/${moco_basename}_tsnr_spinal_level_21.txt" ]; then
        echo "${moco_basename}_tsnr_spinal_level_21.txt already exists, skipping."
    else
		echo "Calculating segmental tSNR.Your input data is $2 in $1"
		
		# Warp template to subject space
		sct_warp_template -d ${moco_basename}_tmean.nii.gz -w reg/${j}/warp_PAM502${moco_basename}_tmean.nii.gz -ofolder masks/${3}
				
		# For each spinal segmental level
		for k in "21" "22" "23" "24" "25"; do 
			# Isolate each segment from template
			fslmaths masks/${3}/template/PAM50_spinal_levels.nii.gz -thr ${k} -uthr ${k} -bin masks/PAM50_spinal_level_${k}_reg_${3}	
			# Extract tSNR per segment
			fslstats tsnr/${moco_basename}_tsnr.nii.gz -k masks/PAM50_spinal_level_${k}_reg_${3} -M >> tsnr/segmental/${moco_basename}_tsnr_spinal_level_${k}.txt
		done
	fi
}

gs () {
	moco_basename=$(basename ${2} .nii.gz)
	anat_basename=$(basename ${3} .nii.gz)
	
	cd ${1}

	if [ -e "gs/${moco_basename}_gs_cord.txt" ]; then
        echo "${moco_basename}_gs_cord.txt already exists, skipping."
    else
		echo "Calculating whole-cord global signal. Your input data is $2 in $1"
		fslstats ${moco_basename}_tmean -k ${anat_basename}_seg_reg -M >> gs/${moco_basename}_gs_cord.txt
	fi
}

cv () {
	moco_basename=$(basename ${2} .nii.gz)
	anat_basename=$(basename ${3} .nii.gz)
	
	cd ${1}
	
	if [ -e "tsnr/cord/${moco_basename}_cv_cord.txt" ]; then
        echo "${moco_basename}_cv_cord.txt already exists, skipping."
    else
		echo "Calculating whole-cord coefficient of variation.Your input data is $2 in $1"
		fslmaths ${moco_basename}_tstd -div ${moco_basename}_tmean cv/${moco_basename}_cv
		fslstats cv/${moco_basename}_cv -k ${anat_basename}_seg_reg -M >> cv/${moco_basename}_cv_cord.txt
		
	fi	
}

# Path of the folder containing all data
dir="/root/dir"

# SCT path
sct_dir="/sct/dir/6.5"

# List of subject IDs
declare -a sub=("DJL240219A" "DJL240305A" "DJL240410F" "DJL240424A" "DJL240425B" "DJL240425C" "DJL240425D" "DJL240521A" "DJL240521B" "DJL240521D")

# For each subject
for i in "${sub[@]}"; do

	# Create subdirectories (only on first run of the code)
	mkdir ${dir}/derivatives/tsnr/lumbar/sub-${i}
	mkdir ${dir}/derivatives/tsnr/cervical/sub-${i}/masks
	mkdir ${dir}/derivatives/tsnr/lumbar/sub-${i}/tsnr
	mkdir ${dir}/derivatives/tsnr/lumbar/sub-${i}/tsnr/cord
	mkdir ${dir}/derivatives/tsnr/lumbar/sub-${i}/tsnr/segmental
	mkdir ${dir}/derivatives/tsnr/lumbar/sub-${i}/reg/
	
	mkdir ${dir}/derivatives/tsnr/lumbar/sub-${i}/gs
	mkdir ${dir}/derivatives/tsnr/lumbar/sub-${i}/cv
	
	for j in "baseline" "satpads"; do

		# Move raw data to derivatives (only on first run of the code)
		cp ${dir}/data/sub-${i}/ses-lumbar/func/sub-${i}_ses-lumbar_task-rest_run-${j}_bold.nii.gz ${dir}/derivatives/tsnr/lumbar/sub-${i}/
		cp ${dir}/data/sub-${i}/ses-lumbar/anat/sub-${i}_ses-lumbar_run-${j}_T2w.nii.gz ${dir}/derivatives/tsnr/lumbar/sub-${i}/
		
		# Run motion correction
		moco ${dir}/derivatives/tsnr/lumbar/sub-${i} sub-${i}_ses-lumbar_task-rest_run-${j}_bold.nii.gz ${j} ${dir}
		
		# Run cord segmentation
		seg ${dir}/derivatives/tsnr/lumbar/sub-${i} sub-${i}_ses-lumbar_task-rest_run-${j}_bold_MCnofilt.nii.gz sub-${i}_ses-lumbar_run-${j}_T2w.nii.gz
	done
	
	# Create disc and conus labels	
	labels ${dir}/code ${dir}/derivatives/tsnr ${i}
	
	for j in "baseline" "satpads"; do
		
		# Create subdirectories (only on first run of the code)
		mkdir ${dir}/derivatives/tsnr/lumbar/sub-${i}/reg/${j}
		mkdir ${dir}/derivatives/tsnr/cervical/sub-${i}/masks/${j}
		mkdir ${dir}/derivatives/tsnr/lumbar/sub-${i}/tsnr/cord/segmental/${j}
		
		# Register to template
		reg ${dir}/derivatives/tsnr/lumbar/sub-${i} sub-${i}_ses-lumbar_task-rest_run-${j}_bold_MCnofilt.nii.gz sub-${i}_ses-lumbar_run-${j}_T2w.nii.gz ${j} ${sct_dir}
		
		# Calculate tSNR and extract it from the whole cord section
		tsnr_cord ${dir}/derivatives/tsnr/lumbar/sub-${i} sub-${i}_ses-lumbar_task-rest_run-${j}_bold_MCnofilt.nii.gz sub-${i}_ses-lumbar_run-${j}_T2w.nii.gz ${j} ${sct_dir}
		
		# Calculate tSNR and extract it from each spinal segmental level		
		tsnr_segmental ${dir}/derivatives/tsnr/lumbar/sub-${i} sub-${i}_ses-lumbar_task-rest_run-${j}_bold_MCnofilt.nii.gz ${j}
		
		# Extract global signal from the whole cord section
		gs ${dir}/derivatives/tsnr/lumbar/sub-${i} sub-${i}_ses-lumbar_task-rest_run-${j}_bold_MCnofilt.nii.gz sub-${i}_ses-lumbar_run-${j}_T2w.nii.gz
		
		# Calculate timeseries coefficient of variation and extract it from the whole cord section
		cv ${dir}/derivatives/tsnr/lumbar/sub-${i} sub-${i}_ses-lumbar_task-rest_run-${j}_bold_MCnofilt.nii.gz sub-${i}_ses-lumbar_run-${j}_T2w.nii.gz
		
	done
done

