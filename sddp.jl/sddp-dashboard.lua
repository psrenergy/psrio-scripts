local function save_dashboard()
    local battery = Battery();
    local hydro = Hydro();
    local powerinjection = PowerInjection();
    local renewable = Renewable();
    local study = Study();
    local system = System();
    local thermal = Thermal();
    local interconnection = Interconnection();
    local dclink = DCLink();

    local suffixes = {
        { title = "", suffix = "" }
    };

    if study:is_genesys() then
        suffixes = {
            { title = " (week)", suffix = "__week" },
            { title = " (day)", suffix = "__day" },
            { title = " (hour)", suffix = "__hour" },
            { title = " (trueup)", suffix = "__trueup" }
        };
    end

    local tab_costs = Dashboard("Costs");
    tab_costs:set_icon("dollar-sign");
    tab_costs:push("# Costs");

    local tab_generation = Dashboard("Generation");
    tab_generation:set_icon("activity");
    tab_generation:push("# Generation");

    for _, item in pairs(suffixes) do
        -- GENERATION --
        local gerter = thermal:load("gerter2" .. item.suffix):aggregate_scenarios(BY_AVERAGE());
        if not gerter:is_hourly() then
            gerter = gerter:aggregate_blocks(BY_SUM());
        end

        local losint = interconnection:load("losint" .. item.suffix):convert("GWh"):aggregate_scenarios(BY_AVERAGE());
        if not losint:is_hourly() then
            losint = losint:aggregate_blocks(BY_SUM());
        end

        local loslnk = dclink:load("loslnk" .. item.suffix):convert("GWh"):aggregate_scenarios(BY_AVERAGE());
        if not loslnk:is_hourly() then
            loslnk = loslnk:aggregate_blocks(BY_SUM());
        end

        local gerhid = hydro:load("gerhid" .. item.suffix):aggregate_scenarios(BY_AVERAGE());
        if not gerhid:is_hourly() then
            gerhid = gerhid:aggregate_blocks(BY_SUM());
        end

        local gergnd = renewable:load("gergnd" .. item.suffix):aggregate_scenarios(BY_AVERAGE());
        if not gergnd:is_hourly() then
            gergnd = gergnd:aggregate_blocks(BY_SUM());
        end

        local gerbat = battery:load("gerbat" .. item.suffix):aggregate_scenarios(BY_AVERAGE()):convert("GWh");
        if not gerbat:is_hourly() then
            gerbat = gerbat:aggregate_blocks(BY_SUM());
        end

        local powinj = powerinjection:load("powinj" .. item.suffix):aggregate_scenarios(BY_AVERAGE());
        if not powinj:is_hourly() then
            powinj = powinj:aggregate_blocks(BY_SUM());
        end

        local demand = system:load("demand" .. item.suffix):aggregate_scenarios(BY_AVERAGE());
        if not demand:is_hourly() then
            demand = demand:aggregate_blocks(BY_SUM());
        end

        local demandel = system:load("demandel" .. item.suffix):aggregate_scenarios(BY_AVERAGE());
        if not demandel:is_hourly() then
            demandel = demandel:aggregate_blocks(BY_SUM());
        end

        local deficit = system:load("defcit" .. item.suffix):aggregate_scenarios(BY_AVERAGE());
        if not deficit:is_hourly() then
            deficit = deficit:aggregate_blocks(BY_SUM());
        end

        local chart = Chart("Generation" .. item.title);
        if gerter:stages() > 2 then
            chart:add_area_stacking(deficit:aggregate_agents(BY_SUM(), "Deficit"), { color = "black" });
            chart:add_area_stacking(gerter:aggregate_agents(BY_SUM(), "Total thermal"), { color = "red" });
            chart:add_area_stacking(gerhid:aggregate_agents(BY_SUM(), "Total hydro"), { color = "blue" });
            chart:add_area_stacking(gergnd:aggregate_agents(BY_SUM(), "Total renewables"), { color = "green" });
            chart:add_area_stacking(gerbat:aggregate_agents(BY_SUM(), "Total battery"), { color = "orange" });
            chart:add_area_stacking(powinj:aggregate_agents(BY_SUM(), "Total power injection"), { color = "teal" });
            chart:add_line(demandel:aggregate_agents(BY_SUM(), "Demand (elastic)"), { color = "deeppink" });
            chart:add_line(demand:aggregate_agents(BY_SUM(), "Demand"), { color = "purple" });
            chart:add_line(losint:aggregate_agents(BY_SUM(), "Interconnection losses"), { color = "grey" });
            chart:add_line(loslnk:aggregate_agents(BY_SUM(), "DC link losses"), { color = "lightgrey" });
        else
            chart:add_column_stacking(deficit:aggregate_agents(BY_SUM(), "Deficit"), { color = "black" });
            chart:add_column_stacking(gerter:aggregate_agents(BY_SUM(), "Total thermal"), { color = "red" });
            chart:add_column_stacking(gerhid:aggregate_agents(BY_SUM(), "Total hydro"), { color = "blue" });
            chart:add_column_stacking(gergnd:aggregate_agents(BY_SUM(), "Total renewables"), { color = "green" });
            chart:add_column_stacking(gerbat:aggregate_agents(BY_SUM(), "Total battery"), { color = "orange" });
            chart:add_column_stacking(powinj:aggregate_agents(BY_SUM(), "Total power injection"), { color = "teal" });
            chart:add_column(demandel:aggregate_agents(BY_SUM(), "Demand (elastic)"), { color = "deeppink" });
            chart:add_column(demand:aggregate_agents(BY_SUM(), "Demand"), { color = "purple" });
            chart:add_column(losint:aggregate_agents(BY_SUM(), "Interconnection losses"), { color = "grey" });
            chart:add_column(loslnk:aggregate_agents(BY_SUM(), "DC link losses"), { color = "lightgrey" });
        end
        tab_generation:push(chart);

        -- COSTS --
        local cmgdem = system:load("cmgdem" .. item.suffix);

        local chart = Chart("Load Marginal Cost per Year" .. item.title);
        chart:add_column(
            cmgdem:aggregate_scenarios(BY_AVERAGE()):aggregate_blocks(BY_AVERAGE()):aggregate_stages(BY_AVERAGE(), Profile.PER_YEAR)
        );
        tab_costs:push(chart);

        if not cmgdem:is_hourly() then
            cmgdem = cmgdem:aggregate_blocks(BY_AVERAGE());
        end
        
        local cmgdem_avg = cmgdem:aggregate_scenarios(BY_AVERAGE()):aggregate_agents(BY_AVERAGE(), "avg");
        local cmgdem_p10 = cmgdem:aggregate_scenarios(BY_PERCENTILE(10)):aggregate_agents(BY_AVERAGE(), "p10");
        local cmgdem_p90 = cmgdem:aggregate_scenarios(BY_PERCENTILE(90)):aggregate_agents(BY_AVERAGE(), "p90");
        
        local chart = Chart("Load Marginal Cost" .. item.title);
        if cmgdem:stages() > 2 then
            chart:add_area_range(cmgdem_p10, cmgdem_p90, { color = "lightblue" });
            chart:add_line(cmgdem_avg, { color = "red" });
        else
            chart:add_column(cmgdem_avg, { color = "red" });
        end
        tab_costs:push(chart);
    end

    local dashboard = tab_generation + tab_costs;
    dashboard:save("dashboard");
end

save_dashboard();
