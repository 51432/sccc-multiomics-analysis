#!/bin/bash

# add a bin directory and additional default locations
export PATH="/hpf/largeprojects/tabori/shared/software/bin:${PATH}"
export PERL5LIB="/hpf/largeprojects/tabori/shared/software/perl5/lib/perl5:${PERL5LIB}"
export PYTHONPATH="/hpf/largeprojects/tabori/shared/software/lib/python3.7:/hpf/largeprojects/tabori/shared/software/lib/python3.7/site-packages:/hpf/largeprojects/tabori/shared/software/lib/python3.7/dyn-lib:${PYTHONPATH}"

# base dirs
resources_dir=/hpf/largeprojects/tabori/shared/resources
software_dir=/hpf/largeprojects/tabori/shared/software
genomes=${resources_dir}/reference_genomes

# 只保留 human/hg38 单一路径：本项目已固定为人类样本，不再维护多物种分支。
organism="${1:-human}"
genome="${2:-hg38}"
mode="${3:-wgs}"

# 这里直接阻断旧参数，避免误用 mouse/mm10 等已删除路径。
if [[ "${organism}" != "human" ]]; then
    echo "Error: this pipeline now supports only human samples (organism=human)."
    return 1
fi
if [[ "${genome}" != "hg38" ]]; then
    echo "Error: this pipeline now supports only hg38 reference (genome=hg38)."
    return 1
fi

# 人类 hg38 公共资源
export reference=${genomes}/hg38/gatk_bundle/Homo_sapiens_assembly38.fasta
export reference_dict=${genomes}/hg38/gatk_bundle/Homo_sapiens_assembly38.dict
export knownsites_snps=${genomes}/hg38/gatk_bundle/1000G_phase1.snps.high_confidence.hg38.vcf.gz
export knownsites_snps_biallelic=${genomes}/hg38/gatk_bundle/1000G_phase1.snps.high_confidence.biallelic.hg38.vcf.gz
export knownsites_indels=${genomes}/hg38/gatk_bundle/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz
export gnomad_resource=${genomes}/hg38/gatk_bundle/af-only-gnomad.hg38.vcf.gz
export gatk_pon=${genomes}/hg38/gatk_bundle/1000g_pon.hg38.vcf.gz
export gatk_pon_location=${genomes}/hg38/gatk_bundle/PoNs

# WES/WGS 仍然是核心流程分支，因此保留 mode 判断。
if [[ "${mode}" == "wes" ]]; then
    export intervals=${genomes}/hg38/AgilentSureSelectV5/SureSelect_All_Exon_50mb_with_annotation_hg38_liftover_BED.removeChrUn.interval_list
    export intervals_bed=${genomes}/hg38/AgilentSureSelectV5/SureSelect_All_Exon_50mb_with_annotation_hg38_liftover_BED.removeChrUn.bed
    export bed30intervals=${genomes}/hg38/AgilentSureSelectV5/SureSelect_All_Exon_50mb_with_annotation_hg38_liftover_BED.removeChrUn.30-bed-files/
else
    export intervals=${genomes}/hg38/gatk_bundle/wgs_calling_regions.hg38.interval_list
    export intervals_bed=${genomes}/hg38/gatk_bundle/wgs_calling_regions.hg38.bed
    export bed30intervals=${genomes}/hg38/gatk_bundle/wgs_calling_regions.hg38.30-bed-files/
fi

# reference-independent locations
export snpeff_jar=/hpf/tools/centos6/snpEff/4.11/snpEff.jar
export snpeff_datadir=${resources_dir}/snpEff_data/4.11/data
export vep_datadir=/hpf/tools/centos6/vep/cache102
export vep_species="homo_sapiens"
export varscan_jar=/hpf/tools/centos6/varscan/2.3.8/VarScan.v2.3.8.jar
export gatk_path=${software_dir}/gatk/gatk-4.2.3.0
export funcotator_databases_s=${resources_dir}/funcotator_dataSources.v1.7.20200521s
export funcotator_databases_g=${resources_dir}/funcotator_dataSources.v1.7.20200521g
export annovar_db=${resources_dir}/humandb

# functions

# estimate walltime length
get_walltime(){
    size=$(du -sc $* | tail -1 | cut -f1)
    walltime=$(echo "scale=0; (${size} * 4)/10000000" | bc)
    if [[ "${walltime}" == 0 ]]; then
        walltime=2
    fi
    echo $walltime
}
export -f get_walltime

# get read groups from illumina header
get_read_group_info(){
  # get the first line
  file $1 | grep "gzip" &> /dev/null
  if [[ "$?" == 0 ]]; then # gzipped
  # get the first line
    head=$(zcat $1 2> /dev/null | head -1 | sed 's/^@//')
  else
    head=$(cat $1 2> /dev/null | head -1 | sed 's/^@//')
  fi
  head_split=(`echo $head | tr ':' '\n'`)
  # default assume illumina
  PL=ILLUMINA
  # sample second arg
  SM=$2
  if [[ "${#head_split[@]}" == 11 ]]; then
    PM=${head_split[0]} # instrument id
    ID="${head_split[1]}-${head_split[3]}" # merge run id with lane id
    PU=${head_split[2]} # flowcell id
    BC=${head_split[10]} # barcode ID
    RG="@RG\\tID:${ID}\\tSM:${SM}\\tLB:${BC}\\tPL:${PL}\\tBC:${BC}\\tPU:${PU}\\tPM:${PM}"
  else
    ID=1 # run id
    RG="@RG\\tID:${ID}\\tSM:${SM}\\tPL:${PL}"
  fi
  echo "$RG"
}
export -f get_read_group_info

# compresses and generates a tabix index
index-vcf(){
    if [[ -e $1.gz ]]; then
        rm $1.gz $1.gz.tbi
    fi
    bgzip $1 && tabix $1.gz
}
export -f index-vcf

# function to look for file
file_lookup(){
    until [[ -e $1 ]]; do
        # checks for the file every minute
        sleep 60
    done
    echo "file $1 found."
    return 0
}
export -f file_lookup

# calculate how long it took to run
# 1st arg: date
# 2nd arg: h|d  (in fraction of days or hours)
how_long(){
  if [[ -f ${1} ]]; then
    start_date=$(head -1 $1)
  else
    start_date="$1"
  fi
  end_date=$(date)
  # calculate total running time
  sds=$(date -d "$start_date" +%s)
  eds=$(date -d "$end_date" +%s)
  # in days
  if [[ "${2}" == "d" ]]; then
    # divided by seconds in a day
    total_time=$( echo "scale=5; ($eds - $sds) / 86400" | bc )
  elif [[ "${2}" == "h" ]]; then
    # divided by seconds in an hour
    total_time=$( echo "scale=5; ($eds - $sds) / 3600" | bc )
  fi
  # add 0 if less than 1
  if [[ $(echo "${total_time} > 1" | bc) == 0 ]]; then
    total_time="0${total_time}"
  fi
  echo $total_time
}
export -f how_long
