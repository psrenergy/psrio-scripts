size = PSR.studies();

study = Study();
labels = study:get_files("(.*\\.csv|.*\\.hdr)");
for i = 1,#labels do
    label = labels[i];
    info("Concatenating file " .. label);

    outputs = {};
    for j = 1,size do 
        output = Generic(j):load(label);
        table.insert(outputs, output);
    end

    concatenate_stages(outputs):save(label .. "-concatenated");
end