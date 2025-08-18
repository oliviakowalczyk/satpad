# Path of the folder containing all data
dir="/root/dir"

for m in "baseline" "satpads"; do
		
	echo "Working on ${m}"
	
	fslmerge -t ${dir}/derivatives/tsnr/lumbar/group/stack_${m} \
	${dir}/derivatives/tsnr/lumbar/sub-*/tsnr/sub-*_ses-lumbar_task-rest_run-${m}_bold_MCnofilt_tsnr_reg.nii.gz
	
	fslmaths ${dir}/derivatives/tsnr/lumbar/group/stack_${m} -Tmean ${dir}/derivatives/tsnr/lumbar/group/stack_${m}_mean
        
done
