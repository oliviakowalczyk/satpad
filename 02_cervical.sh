#!/bin/bash

chop () {
	# read subject, session, and z coordinate variables from a csv file
	while IFS="," read -r subject img chop_z_func; do
		if [ "${3}" = "${subject}" ]; then
			if [ -e "${2}/sub-${subject}/${img}_chop.nii.gz" ]; then
				echo "${img}_chop.nii.gz already exists."
			else
				echo "sub: ${subject}"
				echo "img: ${img}"
				echo "Chop z coordinate: ${chop_z_func}"
				
				cd ${2}/sub-${subject}
				
				chop_z_func_plus_one=$((${chop_z_func} + 1)) # add 1 to chop_z_func value
				
				echo "Separating cord of ${img} at z ${chop_z_func_plus_one}..."
				fslroi ${img} ${img}_chop 0 -1 0 -1 0 ${chop_z_func_plus_one} 0 -1
			fi
		fi
	done < ${1}/chop_z.csv
}

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
		
		# Segment cord on motion corrected data
		sct_deepseg_sc -i ${data_basename}_MCnofilt_tmean.nii.gz -c t2s  
	fi
}

reg () {
	moco_basename=$(basename ${2} .nii.gz)
	anat_basename=$(basename ${3} .nii.gz)
	cd ${1}
	
	if [ -e "${moco}_MCnofilt_tmean_reg.nii.gz" ]; then
        echo "${moco}_MCnofilt_tmean_reg.nii.gz already exists, skipping."
    else
		echo "Running template registration. Your input data is $2 in $1Getting ready to register data to the PAM50 template. Your input data is $2 and $3 in $1"
		echo "Label discs 3-8 on EPI"
		sct_label_utils -i ${moco_basename}_tmean.nii.gz -create-viewer 3:8 -o ${moco_basename}_tmean_labels_disc_3_8.nii.gz
		echo "Label discs 3-8 on T2w "
		sct_label_utils -i ${3} -create-viewer 3:8 -o ${anat_basename}_labels_disc_3_8.nii.gz
		echo "Label discs 1-9 on T2w"
		sct_label_utils -i ${3} -create-viewer 1:9 -o ${anat_basename}_labels_disc_1_9.nii.gz
		
		echo "Generating a mask of the cord using the T2w image"
		sct_deepseg_sc -i ${3} -c t2
		
		echo "Registering T2w data to EPI with disc labels..."
		sct_register_multimodal \
		-i ${3} \
		-iseg ${anat_basename}_seg.nii.gz \
		-ilabel ${anat_basename}_labels_disc_3_8.nii.gz \
		-d ${moco_basename}_tmean.nii.gz \
		-dseg ${moco_basename}_tmean_seg.nii.gz \
		-dlabel ${moco_basename}_tmean_labels_disc_3_8.nii.gz \
		-param step=0,type=label,dof=Tz:step=1,type=seg,algo=centermass:step=2,type=im,algo=syn,\ metric=MI,slicewise=1,smooth=0,iter=3

		echo "Transforming T2w cord mask to EPI space"
		sct_apply_transfo \
		-i ${anat_basename}_seg.nii.gz \
		-d ${moco_basename}_tmean.nii.gz \
		-w warp_${anat_basename}2${moco_basename}_tmean.nii.gz \
		-x nn
		
		echo "Registering T2w image to PAM50 T2w template"
		sct_register_to_template -i ${3} -s ${anat_basename}_seg.nii.gz -ldisc ${anat_basename}_labels_disc_1_9.nii.gz -c t2

		echo "Creating new warp files"
		sct_concat_transfo \
		-d ${4}/data/PAM50/template/PAM50_t2s.nii.gz \
		-w warp_${moco_basename}_tmean2${anat_basename}.nii.gz warp_anat2template.nii.gz \
		-o warp_${moco_basename}_tmean2PAM50.nii.gz

		sct_concat_transfo \
		-d ${moco_basename}_tmean.nii.gz \
		-w warp_template2anat.nii.gz warp_${anat_basename}2${moco_basename}_tmean.nii.gz \
		-o warp_PAM502${moco_basename}_tmean.nii.gz
		
		echo "Registering EPI data to PAM50 cord template via T2w registration warps"
		sct_register_multimodal \
		-i ${4}/data/PAM50/template/PAM50_t2s.nii.gz \
		-iseg ${4}/data/PAM50/template/PAM50_cord.nii.gz \
		-d ${moco_basename}_tmean.nii.gz \
		-dseg ${anat_basename}_seg_reg.nii.gz \
		-param step=1,type=seg,algo=centermassrot:step=2,type=seg,algo=bsplinesyn,slicewise=1,iter=3:step=3,type=im,algo=syn,slicewise=1,iter=1,metric=CC \
		-initwarp warp_PAM502${moco_basename}_tmean.nii.gz \
		-initwarpinv warp_${moco_basename}_tmean2PAM50.nii.gz
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
		
		sct_apply_transfo -i tsnr/${moco_basename}_tsnr.nii.gz -d ${4}/data/PAM50/template/PAM50_t2s.nii.gz -w warp_${moco_basename}_tmean2PAM50.nii.gz -x nn
		mv ${moco_basename}_tsnr_reg.nii.gz tsnr/
	fi
}

tsnr_segmental () {
	moco_basename=$(basename ${2} .nii.gz)
	
	cd ${1}
	
	if [ -e "tsnr/segmental/${moco_basename}_tsnr_spinal_level_1.txt" ]; then
        echo "${moco_basename}_tsnr_spinal_level_1.txt already exists, skipping."
    else
		echo "Calculating segmental tSNR.Your input data is $2 in $1"
		
		# Warp template to subject space
		sct_warp_template -d ${moco_basename}_tmean.nii.gz -w warp_PAM502${moco_basename}_tmean.nii.gz -ofolder masks/${3}
				
		# For each spinal segmental level
		for k in "1" "2" "3" "4" "5" "6" "7" "8"; do 
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
	
	if [ -e "cv/cord/${moco_basename}_cv_cord.txt" ]; then
        echo "${moco_basename}_cv_cord.txt already exists, skipping."
    else
		echo "Calculating whole-cord coefficient of variation.Your input data is $2 in $1"
		fslmaths ${moco_basename}_tstd -div ${moco_basename}_tmean cv/${moco_basename}_cv
		fslstats cv/${moco_basename}_cv -k ${anat_basename}_seg_reg -M >> cv/${moco_basename}_cv_cord.txt
		
	fi	
}

# Path to the study directory
dir="/root/dir"

# SCT path
sct_dir="/sct/dir/6.5"

# List of subject IDs
declare -a sub=("DJL231215B" "DJL240109A" "DJL240111A" "DJL240124A" "DJL240125A" "DJL240207A" "DJL240208A" "DJL240220A" "DJL240221A" "DJL240307A")

# For each subject
for i in "${sub[@]}"; do

	# Create subdirectories (only on first run of the code)
	mkdir ${dir}/derivatives/tsnr/cervical/sub-${i}
	mkdir ${dir}/derivatives/tsnr/cervical/sub-${i}/masks
	mkdir ${dir}/derivatives/tsnr/cervical/sub-${i}/tsnr
	mkdir ${dir}/derivatives/tsnr/cervical/sub-${i}/tsnr/cord
	mkdir ${dir}/derivatives/tsnr/cervical/sub-${i}/tsnr/segmental
	mkdir ${dir}/derivatives/tsnr/cervical/sub-${i}/gs
	mkdir ${dir}/derivatives/tsnr/cervical/sub-${i}/cv
	
	for j in "baseline" "satpads"; do
		
		# Create subdirectories (only on first run of the code)
		mkdir ${dir}/derivatives/tsnr/cervical/sub-${i}/masks/${j}
		
		# Move raw data to derivatives (only on first run of the code)
		cp ${dir}/data/sub-${i}/ses-cervical/func/sub-${i}_ses-cervical_task-rest_run-${j}_bold.nii.gz ${dir}/derivatives/tsnr/sub-${i}/
		cp ${dir}/data/sub-${i}/ses-cervical/anat/sub-${i}_ses-cervical_run-${j}_T2w.nii.gz ${dir}/derivatives/tsnr/sub-${i}/
		
		# Separate brainstem structures based on predefined z coordinate
		chop ${dir}/code ${dir}/derivatives/tsnr ${i}
		
		# Run motion correction and create cord mask on functional data
		moco ${dir}/derivatives/tsnr/cervical/sub-${i} sub-${i}_ses-cervical_task-rest_run-${j}_bold_chop.nii.gz ${j} ${dir}
		
		# Register to template
		reg ${dir}/derivatives/tsnr/cervical/sub-${i} sub-${i}_ses-cervical_task-rest_run-${j}_bold_chop_MCnofilt.nii.gz sub-${i}_ses-cervical_run-${j}_T2w.nii.gz ${sct_dir}
		
		# Calculate tSNR and extract it from the whole cord section
		tsnr_cord ${dir}/derivatives/tsnr/cervical/sub-${i} sub-${i}_ses-cervical_task-rest_run-${j}_bold_chop_MCnofilt.nii.gz sub-${i}_ses-cervical_run-${j}_T2w.nii.gz ${sct_dir}
		
		# Calculate tSNR and extract it from each spinal segmental level
		tsnr_segmental ${dir}/derivatives/tsnr/cervical/sub-${i} sub-${i}_ses-cervical_task-rest_run-${j}_bold_chop_MCnofilt.nii.gz ${j}
		
		# Extract global signal from the whole cord section
		gs ${dir}/derivatives/tsnr/cervical/sub-${i} sub-${i}_ses-cervical_task-rest_run-${j}_bold_chop_MCnofilt.nii.gz sub-${i}_ses-cervical_run-${j}_T2w.nii.gz
		
		# Calculate timeseries coefficient of variation and extract it from the whole cord section
		cv ${dir}/derivatives/tsnr/cervical/sub-${i} sub-${i}_ses-cervical_task-rest_run-${j}_bold_chop_MCnofilt.nii.gz sub-${i}_ses-cervical_run-${j}_T2w.nii.gz

	done
done

