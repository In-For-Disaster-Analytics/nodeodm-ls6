#!/bin/bash

# NodeODM processing script for Tapis
# Arguments: input_dir output_dir

INPUT_DIR=$1
OUTPUT_DIR=$2

echo "NodeODM processing started by ${_tapisJobOwner}"
echo "Input directory: $INPUT_DIR"
echo "Output directory: $OUTPUT_DIR"

# Create output directory
mkdir -p $OUTPUT_DIR

# List input files
echo "Input files found:" > $OUTPUT_DIR/file_listing.txt
if [ -d "$INPUT_DIR" ]; then
    ls -la $INPUT_DIR >> $OUTPUT_DIR/file_listing.txt
    
    # Count image files
    IMAGE_COUNT=$(find $INPUT_DIR -name "*.jpg" -o -name "*.jpeg" -o -name "*.JPG" -o -name "*.JPEG" -o -name "*.png" -o -name "*.PNG" | wc -l)
    echo "Total image files: $IMAGE_COUNT" >> $OUTPUT_DIR/file_listing.txt
    
    # List each image file
    echo "Image files:" >> $OUTPUT_DIR/file_listing.txt
    find $INPUT_DIR -name "*.jpg" -o -name "*.jpeg" -o -name "*.JPG" -o -name "*.JPEG" -o -name "*.png" -o -name "*.PNG" | sort >> $OUTPUT_DIR/file_listing.txt
else
    echo "ERROR: Input directory $INPUT_DIR not found!" >> $OUTPUT_DIR/file_listing.txt
fi

# For now, create a simple processing report
echo "NodeODM Processing Report" > $OUTPUT_DIR/processing_report.txt
echo "========================" >> $OUTPUT_DIR/processing_report.txt
echo "Job Owner: ${_tapisJobOwner}" >> $OUTPUT_DIR/processing_report.txt
echo "Job UUID: ${_tapisJobUUID}" >> $OUTPUT_DIR/processing_report.txt
echo "Processing Time: $(date)" >> $OUTPUT_DIR/processing_report.txt
echo "Input Directory: $INPUT_DIR" >> $OUTPUT_DIR/processing_report.txt
echo "Output Directory: $OUTPUT_DIR" >> $OUTPUT_DIR/processing_report.txt

# Copy file listing to report
echo "" >> $OUTPUT_DIR/processing_report.txt
cat $OUTPUT_DIR/file_listing.txt >> $OUTPUT_DIR/processing_report.txt

echo "NodeODM processing completed. Check output files for results."