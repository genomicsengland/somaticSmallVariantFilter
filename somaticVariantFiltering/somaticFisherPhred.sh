#!/bin/bash

# Submit with 
# bsub -n 12 -J "noiseFlag" -q bio -P Analysis -o logs/somaticFisherPhred_%J.log -e logs/somaticFisherPhred_%J.err  "bash somaticFisherPhred.sh -b tumourBamFile -v somaticVcf -o outputDirectory" 
# e.g. 
# bsub -n 12 -J "noiseFlag" -q bio -P Analysis -o logs/somaticFisherPhred_%J.log -e logs/somaticFisherPhred_%J.err  "bash somaticFisherPhred.sh -b /genomes/by_date/2018-06-25/CANCP41874/CancerLP3000396-DNA_G02_NormalLP3000417-DNA_H02/LP3000396-DNA_G02/Assembly/LP3000396-DNA_G02.bam -v /home/jmitchell1/noiseModelBertha_passArg/somaticVariantFiltering/testInput/LP3000396-DNA_G02.duprem.left.split.reheadered.head6k.vcf.gz -o /home/jmitchell1/noiseModelBertha_passArg/somaticVariantFiltering/testOutput/" 

#Set the cancer test environment to replicate Bertha
source /genomes/software/src/test-venvs/cancer-test/bin/activate

mkdir -p logs

#Arguments are file paths to tumour BAM (produced from the Dragen realigned CRAM for the Canvas component)
#somatic small variant VCF (what would have been the input to cellbase) and create ID from vcf, 
#and output directory
while getopts b:v:o: option
do
case "${option}"
in
b) somBam=${OPTARG};;
v) vcf=${OPTARG};;
o) outDir=${OPTARG};;
esac
done

mkdir -p ${outDir}

#Load modules
module load bcftools/1.9
module load parallel/20170522

#Create sample name (everything before first . in vcf filename)
samplename=${vcf##*/}
samplename=${samplename%%.*}

#Set running directory to directory of this script
DIR=`dirname $0`

#Create directories and file names
vcf_unzip_dir="${outDir}tmpUnzip/"
mkdir -p ${vcf_unzip_dir}
vcf_uz="${vcf_unzip_dir}${samplename}.vcf"

snv_txt_dir="${outDir}vcf_files.snv/"
mkdir -p ${snv_txt_dir}
snvtxt="${snv_txt_dir}${samplename}_snv.txt"

pileup_dir="${outDir}bcftools.mpileup.output/"
mkdir -p ${pileup_dir}
pileup_out="${pileup_dir}${samplename}_snv.bcftools.mpileup.txt"

depth_dir="${outDir}tumour_germline.pileups/"
mkdir -p ${depth_dir}
vcfAD="${depth_dir}${samplename}.snv.vcf"

fisher_dir="${outDir}fisherTest/"
mkdir -p ${fisher_dir}
vcfFisher="${fisher_dir}${samplename}.fisher.snv.vcf"

fisher_vcf_dir="${outDir}fisherVCF/"
mkdir -p ${fisher_vcf_dir}
fisher_vcf="${fisher_vcf_dir}${samplename}.vcf.gz"
fisher_vcf_uz="${fisher_vcf_dir}${samplename}.vcf"

#Extract all SNVs in autosome and sex chromosomes and put in temporary text file
python ${DIR}/writeSNV.py ${vcf} ${snvtxt}

#Perfom pileup (alelle depth count) on tumour BAM at somatic SNV sites
#### Important that this step is run in parallel (e.g. 12 cores looping through chromosomes) ####
parallel -j 12 'bcftools mpileup -q 5 -Q 5 --ff 1024 -A -d 1000 --no-reference -Ou -a INFO/AD,FORMAT/AD -R <(cut -f 1-2 '${snvtxt}' | grep -w chr{}) '${somBam}'  |\
bcftools annotate -x ^INFO/AD,^FORMAT/AD -Ov |\
grep -v '^#' | cut -f 1,2,5,10,11 > '${pileup_dir}'/'${samplename}'.chr{}.out' ::: {1..22} X Y

rm ${pileup_out}
for chrom in {1..22} X Y
do
cat ${pileup_dir}/${samplename}.chr${chrom}.out >> ${pileup_out} 
rm ${pileup_dir}/${samplename}.chr${chrom}.out
done

##Parse pileup output to make usuable for Fisher's Exact Test with PoN
python ${DIR}/parse.bcftools_output.py ${snvtxt} ${pileup_out} > ${vcfAD}

##Perform Fisher's test (R script contains path to PoN on line 10, the PoN should be coppied somewhere accesible)
#### Important that this step is run in parallel (e.g. 12 cores looping through chromosomes) ####


for chrom in {1..22} X Y
do
grep -w chr${chrom} ${vcfAD} > ${depth_dir}${samplename}.chr${chrom}.snv.vcf
done


parallel -j 12 'Rscript --vanilla '${DIR}'/somaticAnnotateFisher_7k.R '${depth_dir}''${samplename}'.chr{}.snv.vcf '${fisher_dir}''${samplename}'.chr{}.fisher.snv.vcf' ::: {1..22} X Y


rm ${vcfFisher}
for chrom in {1..22} X Y
do
cat ${fisher_dir}${samplename}.chr${chrom}.fisher.snv.vcf >> ${vcfFisher}
rm ${fisher_dir}${samplename}.chr${chrom}.fisher.snv.vcf ${depth_dir}${samplename}.chr${chrom}.snv.vcf
done


##Annotate vcf with Fisher's test
gunzip -c ${vcf} > ${vcf_uz}
python ${DIR}/add.fisher.py ${vcf_uz} ${vcfFisher} > ${fisher_vcf_uz}


##Add information about annotation to header and tabix.  These two files ({fisher_vcf} & {fisher_vcf}.tbi) are the only files needed to be kept.
bcftools annotate -h ${DIR}/header_SomaticFisherPhred.txt ${fisher_vcf_uz} -Oz  | bcftools reheader -s ${DIR}/sampleNames.txt -o ${fisher_vcf} 
rm ${fisher_vcf_uz} 
tabix -p vcf ${fisher_vcf}


#Check Fisher annotated vcf has n+3 lines, where n is number of lines in the input vcf

linesFisher=($(zcat ${fisher_vcf} | wc -l))
linesOrgvcf=($(zcat ${vcf} | wc -l))

if [ ${linesFisher} -eq $(( linesOrgvcf + 3 )) ]
then
    echo "Bene, number of lines in Fisher annotated vcf is correct"
else
    echo "ERROR: number of lines in Fisher annotated vcf is not correct: ${linesFisher} vs ${linesOrgvcf}, there should be a difference of 3."
fi

#Check the Fisher annotated vcf has correct number of SomaticFisherPhred annotations

SomaticFisherPhred_annots=($(zgrep SomaticFisherPhred ${fisher_vcf} | wc -l))
SNV_count=($(wc -l ${snvtxt} | awk '{print $1}'))

if [ ${SomaticFisherPhred_annots} -eq $(( SNV_count + 2 )) ]
then
    echo "Bene, Fisher annotated vcf has the correct number of SomaticFisherPhred annotations" 
else
    echo "ERROR: Fisher annotated vcf does not have the correct number of SomaticFisherPhred annotations"
fi
