local hydro = Hydro();
local generic = Generic();
local interconnection = Interconnection();
local interconnection_sum = InterconnectionSum();
local renewable = Renewable();
local study = Study();
local system = System();
local thermal = Thermal();

local number_of_digits_round = 2;

local last_stage = 3;

-- READ INPUT FILE
local toml = study:load_toml("brazil_supply_risk.toml");

tipo_sensib_vazao = toml:get_int("tipo_sensib_vazao");
sensib_vazao2020 = toml:get_double("sensib_vazao2020");
tipo_sensib_gnd = toml:get_int("tipo_sensib_gnd");
tipo_ssensib_gnd_quantilensib_gnd = toml:get_double("sensib_gnd_quantil");

-- fix parameters

local is_sddp = false; -- toml:get_bool("is_sddp");
local is_debug =  false; -- toml:get_bool("is_debug");
local is_complete =  false;

local bool_dead_storage_input = true -- toml:get_bool("bool_dead_storage_input");

local bool_termica_extra = false; -- toml:get_bool("bool_termica_extra");
local input_termica_extra = false; -- toml:get_double("input_termica_extra");

local bool_oferta_extra = true; -- toml:get_bool("bool_oferta_extra");
-- bool_oferta_extra = toml:get_double("ExtraInterc");

local bool_int_extra = false; -- toml:get_bool("bool_int_extra");
local input_int_extra = toml:get_double("ExtraInterc")/100;

local bool_int_add_GW = false;
local input_int_add_GW_extra = -4; --GWm

local bool_demanda_reduzida = false;
-- local bool_demanda_reduzida = toml:get_bool("bool_demanda_reduzida");
-- local input_demanda_reduzida = toml:get_double("input_demanda_reduzida"); -- % -- adicionar opção de GW, além do aumento percentual

-- 6%2020  = 2.7% 0.027
-- 9%2020 = 5.6% 0.056
-- 12%2020 = 8.6% 0.086
local input_demanda_reduzida = -0.086


-- 2020 (JAN-DEZ) = 602970 GWh
-- 2021 (JAN-JUN) = 313263 GWh
local bool_demanda_extra = true;
local input_demanda_aumento_anual_sobre_2020 = toml:get_double("ExtraDemand");


-- local bool_demanda_substituta = toml:get_bool("bool_demanda_substituta"); -- GWh

local bool_potencia = true;
local bool_operacao_limitada_itaipu = true; -- reduz 5GW de itaipu na análise de suprimento de potência
local perda_itaipu_e_extras  = 2.5; --GW

local bool_demand_per_block = false; -- toml:get_bool("bool_demand_per_block");
------------------------------------------------- INPUT -------------------------------------------------

Inflow_energia_mlt = generic:load("enafluMLT"):select_stages(1,11);
Inflow_energia_mlt:save("enafluMLT_", {csv = true});

Inflow_energia_historico_2020 = generic:load("enaflu2020"):select_stages(1,11):convert("GW"):rename_agents({"Histórico 2020 - SU", "Histórico 2020 - SE"});
Inflow_energia_historico_2021 = generic:load("enaflu2021"):convert("GW"):rename_agents({"Histórico 2021 - SU", "Histórico 2021 - SE"});
Inflow_energia_mlt = generic:load("enafluMLT"):select_stages(1,11):convert("GW");
Inflow_energia = system:load("enaf65"):select_stages(1,last_stage):convert("GW"):aggregate_blocks(BY_SUM()); -- rho fixo, 65% do máximo
ena_de_2020_horizonte = 59672.328 -- GWh -- vem do enaflu2020. To do: automatizar
ena_de_2020_horizonte_GWm = 20.38 -- GWm

-- LOAD FATOR ENERGIA ARMAZENADA
-- local fator_energia_armazenada = hydro:load("fatorEnergiaArmazenada", true);

-- LOAD DURACI
local duraci = system.duraci;
if bool_demand_per_block then
    duraci = duraci:select_agents({1}):select_stages(1,last_stage);
else
    duraci = duraci:select_agents({1}):select_stages(1,last_stage):aggregate_blocks(BY_SUM());
end

-- LOAD HYDRO GENERATION
local gerhid = nil;
if bool_demand_per_block then
    gerhid = hydro:load(is_sddp and "gerhid" or "gerhid_KTT", true):convert("GWh"):select_stages(1,last_stage);
    gerhid = gerhid:aggregate_blocks(BY_SUM()):convert("GW") * duraci;
    gerhid = gerhid:convert("GWh");
else
    gerhid = hydro:load(is_sddp and "gerhid" or "gerhid_KTT", true):convert("GWh"):aggregate_blocks(BY_SUM()):select_stages(1,last_stage);
end
local hydro_generation = gerhid:aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "SE + SU");

-- proncura alvo através da sensiblidade desejada
----------------------------------------------
if tipo_sensib_vazao == 2 then
    scenarios = Inflow_energia:scenarios();
    -- calcula alvo usando tipo_ssensib_gnd_quantilensib_gnd
    alvo = sensib_vazao2020 * ena_de_2020_horizonte; -- multiplicar pela ena de 2020
    print("Alvo:");
    print(alvo);
    cenario_hidro = 1; -- começa com cenário e substituiu usando uma busca linear abaixo
    valor_cenario_atual = (Inflow_energia:select_scenarios({cenario_hidro}):convert("GWh"):aggregate_stages(BY_SUM()):aggregate_stages(BY_SUM()):aggregate_agents(BY_SUM(), "ENA_2021"):to_list())[1];
    local distancia_alvo = max(valor_cenario_atual - alvo, -valor_cenario_atual + alvo):to_list()[1];
    for scenario = 1,scenarios,1 do
        valor_cenario_atual = Inflow_energia:select_scenarios({scenario}):convert("GWh"):aggregate_stages(BY_SUM()):aggregate_stages(BY_SUM()):aggregate_agents(BY_SUM(), "ENA_2021"):to_list()[1];
        distancia_alvo_corrente = max(valor_cenario_atual - alvo, -valor_cenario_atual + alvo):to_list()[1];
        if distancia_alvo_corrente < distancia_alvo then
            distancia_alvo = distancia_alvo_corrente;
            cenario_hidro = scenario;
        end
    end
    print("Cenário hidro:");
    print(cenario_hidro);
    hydro_generation = hydro_generation:select_scenarios({cenario_hidro});
end
hydro_generation = hydro_generation:save_and_load("hydro_generation_obrigatorio", {csv=true});

-- LOAD RENEWABLE GENERATION
local gergnd = nil;
if bool_demand_per_block then
    gergnd = renewable:load("gergnd", true):select_stages(1,last_stage);
else
    gergnd = renewable:load("gergnd", true):aggregate_blocks(BY_SUM()):select_stages(1,last_stage);
end
local renewable_generation = gergnd:aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "SE + SU");


-- proncura alvo através do percentil desejado
-- se desejamos usar o percentil de 2021, poderíamos simplificar, ...
-- mas o código abaixo é mais genérico e pode ser extendido facilmente para outros alvos ...
-- como um percentil de 2020 alterando o alvo
----------------------------------------------
if tipo_sensib_gnd == 2 then
    scenarios = renewable_generation:scenarios();
    -- calcula alvo usando tipo_ssensib_gnd_quantilensib_gnd
    alvo = renewable_generation:aggregate_stages(BY_SUM()):aggregate_scenarios(BY_PERCENTILE(tipo_ssensib_gnd_quantilensib_gnd)):to_list()[1];
    print("Alvo:");
    print(alvo);
    cenario_renovavel = 1; -- começa com cenário e substituiu usando uma busca linear abaixo
    valor_cenario_atual = (renewable_generation:select_scenarios({cenario_renovavel}):aggregate_stages(BY_SUM()):to_list())[1];
    local distancia_alvo = max(valor_cenario_atual - alvo, -valor_cenario_atual + alvo):to_list()[1];
    for scenario = 1,scenarios,1 do
        valor_cenario_atual = renewable_generation:select_scenarios({scenario}):aggregate_stages(BY_SUM()):to_list()[1];
        distancia_alvo_corrente = max(valor_cenario_atual - alvo, -valor_cenario_atual + alvo):to_list()[1];
        if distancia_alvo_corrente < distancia_alvo then
            distancia_alvo = distancia_alvo_corrente;
            cenario_renovavel = scenario;
        end
    end
    print("Cenário renovável:");
    print(cenario_renovavel);
    renewable_generation = renewable_generation:select_scenarios({cenario_renovavel});
end
renewable_generation = renewable_generation:save_and_load("renovaveis_selecionadas", {csv=true});


-- LOAD THERMAL GENERATION
local potter = nil;
if bool_demand_per_block then
    potter = thermal:load("potter", true):convert("GW"):select_stages(1,last_stage) * duraci;
    potter = potter:convert("GWh");
else
    potter = thermal:load("potter", true):convert("GWh"):aggregate_blocks(BY_SUM()):select_stages(1,last_stage);
end
local potter_block = thermal:load("potter", true):convert("GWh"):select_stages(1,last_stage);
local thermal_generation = potter:aggregate_scenarios(BY_AVERAGE()):aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "SE + SU");
local thermal_generation_block = potter_block:aggregate_scenarios(BY_AVERAGE()):aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "SE + SU");
thermal_generation = thermal_generation:save_and_load("thermal_generation_temp", {tmp=true, csv=false});

-- LOAD INTERCONNECTION
local capint2 = nil;
if bool_demand_per_block then
    capint2 = interconnection:load("capint2", true):convert("GWh");
else
    capint2 = interconnection:load("capint2", true):convert("GWh"):aggregate_blocks(BY_SUM());
end
capint2_block = interconnection:load("capint2", true):convert("GWh");
local capint2_SE = capint2:select_agents({"SE -> NI", "SE -> NE", "SE -> NO"}):aggregate_agents(BY_SUM(), "SE");
local capint2_SE_block = capint2_block:select_agents({"SE -> NI", "SE -> NE", "SE -> NO"}):aggregate_agents(BY_SUM(), "SE");

-- LOAD INTERCONNECTION SUM
local interc_sum = nil;
if bool_demand_per_block then
    interc_sum = interconnection_sum.ub:select_agents({"Soma   14"}):convert("GWh");
else
    interc_sum = interconnection_sum.ub:select_agents({"Soma   14"}):aggregate_blocks(BY_AVERAGE()):convert("GWh");
end

if bool_demand_per_block then
    interc_sum_2 = capint2:select_agents({"SE -> NO"}):aggregate_agents(BY_SUM(), "Soma   13"):convert("GWh");
    interc_sum_2 = interconnection_sum.ub:select_agents({"Soma   13"}):convert("GWh") + interc_sum_2;
else
    interc_sum_2 = capint2:select_agents({"SE -> NO"}):convert("MW"):aggregate_blocks(BY_AVERAGE()):aggregate_agents(BY_SUM(), "Soma   13"):convert("GWh");
    interc_sum_2 = interconnection_sum.ub:select_agents({"Soma   13"}):aggregate_blocks(BY_AVERAGE()):convert("GWh") + interc_sum_2;
end
-- interc_sum_block = interconnection_sum.ub:select_agents({"Soma   14"}):convert("GWh");

-- DEBUG
if is_debug then 
    duraci:save("duraci_risk");
    hydro_generation:save("gerhid_risk");
    renewable_generation:save("gergnd_risk");
    thermal_generation:save("potter_risk");
    capint2_SE:save("capin2_se");
    interc_sum:save("interc_sum_risk");
    fator_energia_armazenada:save("fator_energia_armazenada_debug");
end

capint2_SE = min(capint2_SE, interc_sum);
capint2_SE = min(capint2_SE, interc_sum_2);
if bool_int_add_GW then
    capint2_SE = capint2_SE:convert("GW") + input_int_add_GW_extra;
    capint2_SE = capint2_SE:convert("GWh");
end
-- capint2_SE_block = min(capint2_SE_block, interc_sum_block):select_stages(1,last_stage);
local capint2_SE_extra = capint2_SE * input_int_extra;
local capint2_SE_extra_block  = capint2_SE_block  * input_int_extra;
-- local capint2_SE_extra_block = capint2_SE_block * input_int_extra;
capint2_SE_extra = capint2_SE_extra * ifelse(study.stage:select_stages(1,last_stage):gt(1), 1, 0);
capint2_SE_extra_block = capint2_SE_extra_block * ifelse(study.stage:select_stages(1,last_stage):gt(1), 1, 0);

capint2_SE = capint2_SE:save_and_load("capin2_se_min_risk");

-- DEBUG
if is_debug then 
    capint2_SE_extra:save("capint2_SE_extra");
end

-- LOAD RHO
local rho = hydro:load("rho", true):select_stages(1,1):reset_stages();
if tipo_sensib_vazao == 2 then
    rho = rho:select_scenarios({cenario_hidro});
end
rho = rho:save_and_load("rho_selecionados", {csv=true});

-- LOAD RHO MAX
local rhomax = hydro:load("rhomax", true):select_stages(1,1):reset_stages();

-- LOAD ENEARM
local volfin = nil;
if is_sddp then
    volfin = hydro:load("volfin", true):select_stages(1,last_stage):reset_stages();
else
    volfin = hydro:load("volini_KTT", true):select_stages(2,last_stage+1):reset_stages();
    if tipo_sensib_vazao == 2 then
        volfin = volfin:select_scenarios({cenario_hidro}):save_and_load("volfin_selecionados", {csv=true});
    end
end
local enearm = (max(0, volfin - hydro.vmin) *  rho):aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"}):convert("GWh");

-- LOAD EARMZM
local earmzm = nil;
if is_sddp then
    earmzm = ((hydro.vmax - hydro.vmin):select_stages(last_stage):reset_stages() *  rhomax):aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"});
else
    earmzm = ((hydro.vmax - hydro.vmin) * rhomax):aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"});
    earmzm = earmzm:select_stages(1,1):reset_stages():convert("GWh");
end

-- LOAD DEMAND
local demand = nil;
local input_demanda_extra = nil;
if bool_demanda_substituta then
    demand = generic:load("demanda_substituta", true);
else
    if bool_demand_per_block then
        demand = system:load("demand", true):select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "SE + SU"):select_stages(1,last_stage);
    else
        demand = system:load("demand", true):aggregate_blocks(BY_SUM()):select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "SE + SU"):select_stages(1,last_stage);
    end
    -- 2020 (JAN-DEZ) = 602,970 GWh
    -- 2021 (JAN-JUN) = 313,263 GWh
    -- 2021 (JULHO-DEZ prev) =  269,392.70 GWh

    -- pmo junho
    -- local acontecido_2020_total = 602970; --GWh
    -- local acontecido_2021_1_semestre = 313263; --GWh
    -- local previsao_atual_2021_2_semetre = 307610; --GWh


    -- pmo julho
    local acontecido_2020_total = 602970.408; --GWh
    local acontecido_2021_1_semestre = 362948.856; --GWh - 362825.462
    local previsao_atual_2021_2_semetre = 266021.554; --GWh

    local realizado_agosto = 51213.24; -- atualizar depois, numero provisório usando a previsão + ande
    acontecido_2021_1_semestre = acontecido_2021_1_semestre + realizado_agosto;
    previsao_atual_2021_2_semetre = previsao_atual_2021_2_semetre - realizado_agosto;

    local nova_demanda_2021_total = (1+input_demanda_aumento_anual_sobre_2020/100) * acontecido_2020_total;
    local nova_demanda_2021_2_semestre = nova_demanda_2021_total - acontecido_2021_1_semestre;
    input_demanda_extra = nova_demanda_2021_2_semestre / previsao_atual_2021_2_semetre - 1;
    -- input_demanda_extra:save("input_demanda_extra", {csv=true});
    print("Aumento de demanda:")
    print(input_demanda_extra)
    if bool_demanda_reduzida then
        demand = (1 - input_demanda_reduzida) * demand;
    end
    if bool_demanda_extra then
        demand = (1 + input_demanda_extra) * demand;
    end
end
demand = demand:select_stages(1,last_stage);

-- MAX GENERATION
print("Cenarios por input");
print(hydro_generation:scenarios());
print(renewable_generation:scenarios());
print(thermal_generation:scenarios());
print(capint2_SE:scenarios());
local generation = hydro_generation + renewable_generation + thermal_generation + capint2_SE;
if bool_int_extra then
    generation = generation + capint2_SE_extra;
end
if bool_termica_extra then
    generation = generation + (input_termica_extra * duraci):force_unit("GWh");
end
if bool_oferta_extra then
    oferta_extra = generic:load("extra_generation", true):convert("GWh");
    -- oferta_extra = generic:load("extra_generation_2", true):convert("GWh");
    generation = generation + oferta_extra:aggregate_agents(BY_SUM(), "SE + SU");
end
generation = generation:select_stages(1,last_stage);
generation:save("generation", {tmp = true, csv=false});

-- MISMATCH
local deficit = ifelse((demand - generation):gt(0), demand - generation, 0);
local demanda_residual = (demand - generation):select_stages(1,last_stage):convert("GW");

-- DEFICIT SOMA DE MAIO A NOVEMBRO
local mismatch_stages = deficit:select_stages(1,last_stage):rename_agents({"Mismatch - balanço hídrico"}):convert("GW"):save_and_load("mismatch_stages");
local deficit_sum = deficit:select_stages(1,last_stage):aggregate_blocks(BY_SUM()):aggregate_stages(BY_SUM());
local mismatch = deficit_sum:save_and_load("mismatch", {csv=true});

ifelse(deficit_sum:gt(1), 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"Mismatch - balanço hídrico"}):save("mismatch_risk");

local enearm_SU_ini_stage = enearm:select_agents({"SUL"});
local enearm_SE_ini_stage = enearm:select_agents({"SUDESTE"});

-- ENERGIA ARMAZENADA DO SUL E SUDESTE
local enearm_SU = enearm:select_agents({"SUL"}):select_stages(last_stage);
local enearm_SE = enearm:select_agents({"SUDESTE"}):select_stages(last_stage);

enearm_SU_ini = enearm_SU;
enearm_SE_ini = enearm_SE;

local earmzm_max_SU = earmzm:select_agents({"SUL"});
local earmzm_max_SE = earmzm:select_agents({"SUDESTE"});

if is_debug then
    generation:save("max_generation");
    duraci:save("duraci_KTT");
    demand:save("demand_agg");
    enearm_SE:save("enearm_SE");
    enearm_SU:save("enearm_SU");
    deficit_sum:save("deficit_sum");
    enearm_SU_ini_stage:save("enearm_SU_ini_stage");
    enearm_SE_ini_stage:save("enearm_SE_ini_stage");
    demanda_residual:save("demanda_residual");
end

-- LOAD ENERGIA MORTA
local energiamorta = hydro:load("dead_energy", true):select_stages(last_stage):aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"}):convert("GWh");
if is_debug then energiamorta:save("energiamorta_sistema"); end

local energiamorta_SE = nil;
local energiamorta_SU = nil;
if bool_dead_storage_input then
    energiamorta_SE = energiamorta:select_agents({"SUDESTE"}); -- energiamorta:select_agents({"SUDESTE"});
    energiamorta_SU = energiamorta:select_agents({"SUL"}); --  energiamorta:select_agents({"SUL"});
else
    -- ignorando volume morto e aplicando meta 2 para achar energia morta
    energiamorta_SE = earmzm_max_SE * 0.06;
    energiamorta_SU = earmzm_max_SU * 0.06;
end

local earmzm_SE_level0 = earmzm_max_SE * 0.15;

local earmzm_SU_level1 = earmzm_max_SU * 0.3;
local earmzm_SE_level1 = earmzm_max_SE * 0.1;

local earmzm_SU_level2 = earmzm_max_SU * 0.06;
local earmzm_SE_level2 = earmzm_max_SE * 0.06;

-- acima de 0.06 -> susto
-- abaixo de 0.06 -> desespero

-- RISCO DE VIOLAÇÃO DOS NÍVEIS ONS A PRIORI
local has_SE_level0_violation = enearm_SE:le(earmzm_SE_level0); -- only SE has level 0
local has_SU_level1_violation = enearm_SU:le(earmzm_SU_level1);
local has_SE_level1_violation = enearm_SE:le(earmzm_SE_level1);
local has_SU_level2_violation = enearm_SU:le(earmzm_SU_level2);
local has_SE_level2_violation = enearm_SE:le(earmzm_SE_level2);

ifelse(has_SE_level0_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUDESTE - level 0 (15%)"}):save("enearm_risk_level0_SE");
ifelse(has_SU_level1_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUL - level 1 (30%)"}):save("enearm_risk_level1_SU");
ifelse(has_SE_level1_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUDESTE - level 1 (10%)"}):save("enearm_risk_level1_SE");
ifelse(has_SU_level1_violation | has_SE_level0_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUL or SUDESTE - level 0"}):save("enearm_risk_level0_SE_or_SU");
ifelse(has_SU_level1_violation | has_SE_level1_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUL or SUDESTE - level 1"}):save("enearm_risk_level1_SE_or_SU");

ifelse(has_SU_level2_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUL - level 2 (6%)"}):save("enearm_risk_level2_SU");
ifelse(has_SE_level2_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUDESTE - level 2 (6%)"}):save("enearm_risk_level2_SE");
ifelse(has_SU_level2_violation | has_SE_level2_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUL or SUDESTE - level 2"}):save("enearm_risk_level2_SE_or_SU");

local function get_target(current_energy_se, max_energy_se, current_energy_su, max_energy_su, min_level_su, min_level_se)
	local meta_su_1 = max(max_energy_su * 0.06, min_level_su);
	local meta_su_2 = max(max_energy_su * 0.30, min_level_su);
    local meta_se_1 = max(max_energy_se * 0.06, min_level_se);
	local meta_se_2 = max(max_energy_se * 0.10, min_level_se);
    local meta_su = ifelse(current_energy_se:gt(meta_se_2) & current_energy_su:gt(meta_su_2), meta_su_2, ifelse(current_energy_se:gt(meta_se_1) & current_energy_su:gt(meta_su_1), meta_su_1, min_level_su));
    local meta_se = ifelse(current_energy_se:gt(meta_se_2) & current_energy_su:gt(meta_su_2), meta_se_2, ifelse(current_energy_se:gt(meta_se_1) & current_energy_su:gt(meta_su_1), meta_se_1, min_level_se));
    return meta_su, meta_se
end

local function get_current_energy(deficit, target_S1, current_energy_S1, max_energy_S1, target_S2, current_energy_S2, max_energy_S2, ite, agent)
    local current_energy_S1_useful_storage = (current_energy_S1 - target_S1) / (max_energy_S1 - target_S1);
    local current_energy_S2_useful_storage = (current_energy_S2 - target_S2) / (max_energy_S2 - target_S2);

    local has_deficit = deficit:gt(1);
    local hit_target = current_energy_S1:gt(target_S1) & current_energy_S2:gt(target_S2);
    
    if is_debug then
        has_deficit:save("has_deficit" .. agent .. tostring(ite));
        hit_target:save(("hit_target" .. agent .. tostring(ite)));
        current_energy_S2:save("current_energy_S2" .. agent .. tostring(ite));
        (current_energy_S2 - deficit):save("first_value" .. agent .. tostring(ite));
        (target_S2 + current_energy_S1_useful_storage * (max_energy_S2-target_S2)):save("second_value" .. agent .. tostring(ite));
    end
    
    return 
    ifelse(has_deficit, 
        ifelse(hit_target,
            ifelse(current_energy_S2_useful_storage:gt(current_energy_S1_useful_storage),
                max(current_energy_S2 - deficit, target_S2 + current_energy_S1_useful_storage * (max_energy_S2-target_S2)),
                current_energy_S2                                                                                   
            ),
            current_energy_S2
        ),
        current_energy_S2
    );
end

for i = 1,3,1 do 
    print("iteration: " .. tostring(i) .. ": ")

    local target_SU, target_SE = get_target(enearm_SE, earmzm_max_SE, enearm_SU, earmzm_max_SU, energiamorta_SU, energiamorta_SE);
    target_SE = target_SE:save_and_load("target_SE_it" .. tostring(i));
    target_SU = target_SU:save_and_load("target_SU_it" .. tostring(i));
    local current_energy_SE_useful_storage = (enearm_SE - target_SE) / (earmzm_max_SE - target_SE);
    local current_energy_SU_useful_storage = (enearm_SU - target_SU) / (earmzm_max_SU - target_SU);
    
    if is_debug then
        (enearm_SE - target_SE):save("numerador" .. tostring(i));
        (earmzm_max_SE - target_SE):save("denominador" .. tostring(i));
        current_energy_SE_useful_storage:save("percent_1_SE_it" .. tostring(i));
        current_energy_SU_useful_storage:save("percent_1_SU_it" .. tostring(i));
    end

    local energy_SE = get_current_energy(deficit_sum, target_SU, enearm_SU, earmzm_max_SU, target_SE, enearm_SE, earmzm_max_SE, i, "SE");
    local energy_SU = get_current_energy(deficit_sum, target_SE, enearm_SE, earmzm_max_SE, target_SU, enearm_SU, earmzm_max_SU, i, "SU");
    
    if is_debug then
        energy_SE:save("enearm_SE1_it" .. tostring(i));
        energy_SU:save("enearm_SU1_it" .. tostring(i));
    end
    energy_SE = energy_SE:save_and_load("enearm_SE1_it" .. tostring(i));
    energy_SU = energy_SU:save_and_load("enearm_SU1_it" .. tostring(i));

    local current_energy_SE_useful_storage = (energy_SE - target_SE) / (earmzm_max_SE - target_SE);
    local current_energy_SU_useful_storage = (energy_SU - target_SU) / (earmzm_max_SU - target_SU);
    
    if is_debug then
        current_energy_SE_useful_storage:save("percent_2_SE_it" .. tostring(i));
        current_energy_SU_useful_storage:save("percent_2_SU_it" .. tostring(i));
    end

    deficit_sum = deficit_sum - (enearm_SE - energy_SE) - (enearm_SU - energy_SU);
    enearm_SE = energy_SE;
    enearm_SU = energy_SU;
    local pode_esvaziar = enearm_SE - target_SE + enearm_SU - target_SU;
    
    if is_debug then
        deficit_sum:save("deficit_sum1_it" .. tostring(i));
        pode_esvaziar:save("pode_esvaziar_it" .. tostring(i));
    end

    local nao_pode_atender = deficit_sum:gt(pode_esvaziar:convert("GWh"));
    enearm_SE = ifelse(nao_pode_atender, target_SE, enearm_SE - deficit_sum * (enearm_SE - target_SE)/pode_esvaziar):save_and_load("enearm_SE_it" .. tostring(i));
    enearm_SU = ifelse(nao_pode_atender, target_SU, enearm_SU - deficit_sum * (enearm_SU - target_SU)/pode_esvaziar):save_and_load("enearm_SU_it" .. tostring(i));
    deficit_sum = ifelse(nao_pode_atender, deficit_sum - pode_esvaziar, 0):save_and_load("deficit_sum_it" .. tostring(i));
end

earmzm_SE_level1:save("earmzm_SE_level1");
earmzm_SE_level2:save("earmzm_SE_level2");
earmzm_SU_level1:save("earmzm_SU_level1");
earmzm_SU_level2:save("earmzm_SU_level2");

deficit_sum:rename_agents({"Deficit"}):reset_stages():save("deficit_sum_final");

local enearm_SE_final = enearm_SE:rename_agents({"SUDESTE"}):save_and_load("enearm_SE_final");
local enearm_SU_final = enearm_SU:rename_agents({"SUL"}):save_and_load("enearm_SU_final");
(enearm_SE - enearm_SE_final):save("geracao_hidro_extra_SE");
(enearm_SU - enearm_SU_final):save("geracao_hidro_extra_SU");

 -- RISCO DE VIOLAÇÃO DOS NÍVEIS ONS A POSTEIORIE
local has_SE_level0_violation = enearm_SE:le(earmzm_SE_level0); -- only SE has level 0
local has_SU_level1_violation = enearm_SU:le(earmzm_SU_level1);
local has_SE_level1_violation = enearm_SE:le(earmzm_SE_level1);
local has_SU_level2_violation = enearm_SU:le(earmzm_SU_level2);
local has_SE_level2_violation = enearm_SE:le(earmzm_SE_level2);

ifelse(has_SU_level1_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUL - nível 1 (30%)"}):save("enearm_final_risk_level1_SU");
ifelse(has_SE_level0_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUDESTE - nível 0 (15%)"}):save("enearm_final_risk_level0_SE");
ifelse(has_SE_level1_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUDESTE - nível 1 (10%)"}):save("enearm_final_risk_level1_SE");

ifelse(has_SU_level1_violation | has_SE_level0_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUL or SUDESTE - nível 0"}):save("enearm_final_risk_level0_SE_or_SU");
ifelse(has_SU_level1_violation | has_SE_level1_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUL or SUDESTE - nível 1"}):save("enearm_final_risk_level1_SE_or_SU");

ifelse(has_SU_level2_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUL - nível 2 (6%)"}):save("enearm_final_risk_level2_SU");
ifelse(has_SE_level2_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUDESTE - nível 2 (6%)"}):save("enearm_final_risk_level2_SE");
ifelse(has_SU_level2_violation | has_SE_level2_violation, 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"SUL or SUDESTE - level 2"}):save("enearm_final_risk_level2_SE_or_SU");

local deficit_final_risk = ifelse(deficit_sum:gt(1), 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):rename_agents({"Deficit risk"}):reset_stages():save_and_load("deficit_final_risk");

-- local deficit_stages = ifelse(mismatch:ne(0), mismatch_stages * (deficit_sum / mismatch), 0.0)
-- -- deficit apenas nos 3 ultimos estágios
-- deficit_first_stages = deficit_stages:select_stages(1,last_stage-3):reset_stages():aggregate_stages(BY_SUM());
-- deficit_last_stages = deficit_stages:select_stages(last_stage-2,last_stage):reset_stages():aggregate_stages(BY_SUM());
-- -- local deficit_stages = ifelse(deficit_last_stages:ne(0), deficit_stages * (deficit_last_stages + deficit_first_stages)/deficit_last_stages, 0.0);
-- deficit_stages = deficit_stages + deficit_first_stages/3; -- divide igualmente os deficit dos dois primeiros estágios nos últimos
-- deficit_stages = deficit_stages * ifelse(study.stage:gt(last_stage-3), 1, 0); -- zera o deficit dos 2 primerios estágios, já foram redistribuídos nos demais
-- deficit_stages = deficit_stages:convert("GW");


-- divide deficit total proporcional ao mismatch_stages entre todos os estagios
local deficit_stages = ifelse(mismatch:ne(0), mismatch_stages * (deficit_sum / mismatch), 0.0)
-- aloca o deficit apenas nos 3 ultimos estágios, dividingo igualmente o deficit dos primeiros estagios nos 3 últimos
if last_stage > 3 then
    deficit_first_stages = deficit_stages:select_stages(1,last_stage-3):reset_stages():aggregate_stages(BY_SUM());
    deficit_last_stages = deficit_stages:select_stages(last_stage-2,last_stage):reset_stages():aggregate_stages(BY_SUM());
    deficit_stages = deficit_stages + deficit_first_stages/3; -- divide igualmente os deficit dos dois primeiros estágios nos últimos
    deficit_stages = deficit_stages * ifelse(study.stage:gt(last_stage-3), 1, 0); -- zera o deficit dos 2 primerios estágios, já foram redistribuídos nos demais
end
deficit_stages = deficit_stages:convert("GW");

local deficit_percentual = (deficit_sum/(demand:aggregate_blocks(BY_SUM()):select_stages(last_stage-2,last_stage):reset_stages():aggregate_stages(BY_SUM()))):convert("%"):save_and_load("deficit_percentual");

local minimum_deficit_threshold = 1;
local has_deficit = ifelse(deficit_sum:gt(minimum_deficit_threshold), 1, 0);
cenarios_normal = (1 - ifelse(has_SU_level1_violation | has_SE_level1_violation, 1, 0)):save_and_load("cenarios_normal");
cenarios_atencao = (ifelse(has_SU_level1_violation | has_SE_level1_violation, 1, 0) - has_deficit):save_and_load("cenarios_atencao");
cenarios_racionamento = has_deficit:save_and_load("cenarios_racionamento");

deficit_stages:save("deficit_stages", {csv = true});

-- uso de energia por estagio
uso_energia_por_estagio = mismatch_stages - deficit_stages;
uso_energia = uso_energia_por_estagio:aggregate_stages(BY_SUM()):reset_stages();
local stages = uso_energia_por_estagio:stages();
for stage = 1,stages,1 do
    local month = uso_energia_por_estagio:month(stage);
    uso_energia_por_estagio_acumulado_temp = uso_energia_por_estagio:select_stages(1,stage):aggregate_stages(BY_SUM());
    if stage == 1 then
        uso_energia_por_estagio_acumulado = uso_energia_por_estagio_acumulado_temp;
    else
        uso_energia_por_estagio_acumulado = concatenate_stages(uso_energia_por_estagio_acumulado, uso_energia_por_estagio_acumulado_temp);
    end
end
uso_energia_por_estagio:save("uso_energia_por_estagio", {csv = true});
uso_energia_por_estagio_acumulado:save("uso_energia_por_estagio_acumulado", {csv = true});
enearm_SU_stages = enearm_SU_ini:reset_stages() + (enearm_SU_final:reset_stages() - enearm_SU_ini:reset_stages()) * uso_energia_por_estagio_acumulado/uso_energia;
enearm_SE_stages = enearm_SE_ini:reset_stages() + (enearm_SE_final:reset_stages() - enearm_SE_ini:reset_stages()) * uso_energia_por_estagio_acumulado/uso_energia;


--------------------------------------
---------- violacao usinas -----------
--------------------------------------

-- min outflow
local minimum_outflow_violation = hydro:load("minimum_outflow_violation");
local minimum_outflow = hydro.min_total_outflow;
local minimum_outflow_cronologico = hydro.min_total_outflow_modification;
local minimum_outflow_valido = max(minimum_outflow, minimum_outflow_cronologico):select_stages(1,last_stage);

-- irrigation
local irrigation_violation = hydro:load("irrigation_violation");
local irrigation = hydro.irrigation:select_stages(1,last_stage);

-- turbinamento
local minimum_turbining_violation = hydro:load("minimum_turbining_violation");
local minimum_turbining = hydro.qmin:select_stages(1,last_stage);

local obrigacao_total = max(minimum_turbining, minimum_outflow_valido) + irrigation;
local violacao_total = max(irrigation_violation, minimum_outflow_violation) + irrigation_violation;
local total_violation_percentual = (violacao_total:aggregate_blocks(BY_AVERAGE()):aggregate_stages(BY_SUM())/obrigacao_total:aggregate_blocks(BY_AVERAGE()):aggregate_stages(BY_SUM())):convert("%"):save_and_load("total_violation_percentual");

if is_debug then
    -- conferir se agregacao em estágios deve ser antes ou depois da divisão
    (minimum_outflow_violation:aggregate_blocks(BY_AVERAGE()):aggregate_stages(BY_SUM())/minimum_outflow_valido:aggregate_blocks(BY_AVERAGE()):aggregate_stages(BY_SUM())):convert("%"):save("minimum_outflow_violation_percentual");
    (irrigation_violation:aggregate_blocks(BY_AVERAGE()):aggregate_stages(BY_SUM())/irrigation:aggregate_blocks(BY_AVERAGE()):aggregate_stages(BY_SUM())):convert("%"):save("irrigation_violation_percentual");
    (minimum_turbining_violation:aggregate_blocks(BY_AVERAGE()):aggregate_stages(BY_SUM())/minimum_turbining:aggregate_blocks(BY_AVERAGE()):aggregate_stages(BY_SUM())):convert("%"):save("minimum_turbining_violation_percentual");
end

--------------------------------------
---------- dashboard -----------------
--------------------------------------

local function add_percentile_layers(chart, output, force_unit, to_round)    
    if to_round then
        output = output:round(number_of_digits_round)
    end
    local p_min = output:aggregate_scenarios(BY_PERCENTILE(5)):rename_agents({"Intervalo de confiança de 90%"});
    local p_max = output:aggregate_scenarios(BY_PERCENTILE(95)):rename_agents({""});
    local avg = output:aggregate_scenarios(BY_AVERAGE()):rename_agents({"Média"});

    if force_unit then
        chart:add_area_range(p_min, p_max, {color="#77a1e5", yUnit=force_unit});
        chart:add_line(avg, {color="#000000", yUnit=force_unit});
    else
        chart:add_area_range(p_min, p_max, {color="#77a1e5"});
        chart:add_line(avg, {color="#000000"});
    end

    return chart
end

-- charts de deficit
local dashboard2 = Dashboard("Energia");

md = Markdown();
md:add("# Energia");
md:add("## Suprimento de Energia")
md:add("Aqui, apresentamos os gráficos dos Energy Reports de Junho e Julho, mas, agora, com as hipóteses selecionadas pelo usuário do Dashboard.");
md:add("A figura a seguir mostra o balanço médio de demanda e geração obrigatória. A linha contínua representa a demanda média mensal e as colunas indicam os componentes da oferta. Quando as colunas estão abaixo da linha continua temos um “gap” que chamamos demanda residual que deve ser atendida por geração despachável hídrica do Sul e Sudeste, esvaziando os reservatórios. Portanto, quanto maior a diferença, maior o esvaziamento dos reservatórios, e maior o risco de problemas de suprimento. O contrário também é verdadeiro: a redução da diferença através de um aumento da oferta permite preservar os reservatórios e reduzir o risco de suprimento.");
md:add("\n");
md:add("Os componentes de geração são:");
    md:add("- Geração térmica máxima nas regiões Sudeste e Sul;");
    md:add("- Capacidade máxima de importação das regiões Nordeste e Norte para a região Sudeste. A situação das regiões Nordeste e Norte é relativamente confortável. Como consequência, as regiões Nordeste e Norte estão transferindo o máximo possível de energia para a região Sudeste;");
    md:add("- Valor esperado da geração renovável não controlável no Sudeste e Sul (eólica, solar, biomassa e PCHs não controladas pelo ONS);");
    md:add("- Geração hidroelétrica obrigatória resultante das defluências mínimas por uso múltiplo. É calculada multiplicando as defluências resultantes da operação probabilística com o modelo de simulação de usos múltiplos (SUM) desenvolvido pela PSR (ver edição anterior do ER) pelos coeficientes de produção das usinas ajustados pelo respectivo armazenamento (variação não linear do coeficiente com a altura de queda) em cada cenário hidrológico;");
    md:add("- As demais componentes são as hipóteses selecionadas pelo usuário na tabela interface.");
    md:add("- Valor esperado da geração renovável não controlável no Sudeste e Sul (eólica, solar, biomassa e PCHs não controladas pelo ONS);");
md:add("\n");
dashboard2:push(md);
dashboard2:push("\n");

local chart2_1 = Chart("Oferta x Demanda – Sul e Sudeste (valores médios)");
if bool_termica_extra then
    chart2_1:add_column_stacking(
        ((input_termica_extra * duraci):force_unit("GWh")):aggregate_scenarios(BY_AVERAGE()):rename_agents({"Oferta extra"}):convert("GW"):round(number_of_digits_round), 
    {color="red", yUnit="GWm"}); -- to do: checar cor
end
local chart2_1 = Chart("Oferta x Demanda – Sul e Sudeste (valores médios)");
if bool_oferta_extra then
    chart2_1:add_column_stacking(
        oferta_extra:select_agents({"Gas"}):aggregate_scenarios(BY_AVERAGE()):convert("GW"):round(number_of_digits_round), 
        {color="#800020", yUnit="GWm"}); -- to do: checar cor
    chart2_1:add_column_stacking(
        oferta_extra:select_agents({"Argentina"}):aggregate_scenarios(BY_AVERAGE()):convert("GW"):round(number_of_digits_round), 
        {color="#74ACDF", yUnit="GWm"}); -- to do: checar cor
    chart2_1:add_column_stacking(
        oferta_extra:select_agents({"Uruguai"}):aggregate_scenarios(BY_AVERAGE()):convert("GW"):round(number_of_digits_round), 
        {color="#FCD116", yUnit="GWm"}); -- to do: checar cor
    chart2_1:add_column_stacking(
        oferta_extra:select_agents({"Oleo"}):aggregate_scenarios(BY_AVERAGE()):convert("GW"):round(number_of_digits_round), 
        {color="black", yUnit="GWm"}); -- to do: checar cor
    chart2_1:add_column_stacking(
        oferta_extra:select_agents({"Extras"}):aggregate_scenarios(BY_AVERAGE()):convert("GW"):round(number_of_digits_round), 
        {color="purple", yUnit="GWm"}); -- to do: checar cor
end 

if bool_int_extra then
    chart2_1:add_column_stacking(
        capint2_SE_extra:aggregate_scenarios(BY_AVERAGE()):rename_agents({"NO+NE extra"}):convert("GW"):round(number_of_digits_round), 
        {color="#808080", yUnit="GWm"}
    ); -- to do: checar cor
end

local oferta_termica = thermal_generation:aggregate_scenarios(BY_AVERAGE()):rename_agents({"Oferta térmica"}):convert("GW"):round(number_of_digits_round);
chart2_1:add_column_stacking(oferta_termica, {color="red", yUnit="GWm"});

local importacao_NO_NE = generic:load("capin2_se_min_risk", true):aggregate_scenarios(BY_AVERAGE()):rename_agents({"Importação do NO+NE"}):convert("GW"):round(number_of_digits_round);
chart2_1:add_column_stacking(importacao_NO_NE, {color="#e9e9e9", yUnit="GWm"});

local geracao_renovavel_media = renewable_generation:aggregate_scenarios(BY_AVERAGE()):rename_agents({"Geração renovável + biomassa"}):convert("GW"):round(number_of_digits_round);
chart2_1:add_column_stacking(geracao_renovavel_media, {color="#40E0D0", yUnit="GWm"}); --#40E0D0 #ADD8E6

local geracao_hidrica_obrigatoria = hydro_generation:aggregate_scenarios(BY_AVERAGE()):rename_agents({"Geração hídrica obrigatória"}):convert("GW"):round(number_of_digits_round);
chart2_1:add_column_stacking(geracao_hidrica_obrigatoria, {color="#0038A8", yUnit="GWm"}); -- #0000ff 0038A8 4c4cff

-- CUIDADO MUDAR NOME - demand e demanda!
local demanda = demand:aggregate_scenarios(BY_AVERAGE()):rename_agents({"Demanda"}):convert("GW"):round(number_of_digits_round);
chart2_1:add_line(demanda, {color="#000000", yUnit="GWm"});
dashboard2:push(chart2_1);

if is_debug then
    concatenate(
        oferta_termica,
        importacao_NO_NE,
        geracao_renovavel_media,
        geracao_hidrica_obrigatoria,
        demanda
    ):save("oferta_parcelas");
end

local enearm_final_risk_level0_SE_or_SU = generic:load("enearm_final_risk_level0_SE_or_SU", true):rename_agents({"SE+SU"});
local enearm_final_risk_level1_SE_or_SU = generic:load("enearm_final_risk_level1_SE_or_SU", true):rename_agents({"SE+SU"});

enearm_final_risk_level0_SE_or_SU_pie = 100 - enearm_final_risk_level1_SE_or_SU;
enearm_final_risk_level1_SE_or_SU_pie = enearm_final_risk_level1_SE_or_SU - deficit_final_risk;
enearm_final_risk_level2_SE_or_SU_pie = deficit_final_risk;

md = Markdown();
md:add("## Risco de suprimento de energia");
md:add("A análise operativa é realizada para uma amostra de 1200 cenários (ou seleção do usuário) que representam condições operativas do sistema até o final do ano, associadas a uma combinação de realização hidrologia, vento e sol.");
md:add("Essa amostra permite calcular o risco de suprimento de energia, medido pelo percentual de cenários, nos quais ocorre algum problema. Os riscos foram classificados em três segmentos:");
    md:add("- \"Normal\" (Verde): percentual (%) dos cenários simulados nos quais a energia armazenada das regiões Sudeste e Sul ficou acima das metas determinadas pelo ONS para o final de novembro (% de energia armazenada): 10% para a região Sudeste e 30% para a região Sul. Para estes cenários a situação de suprimento é considerada normal, pois não há problemas de suprimento de energia ou de atendimento à demanda de ponta.");
    md:add("- \"Atenção\" (Amarelo): % dos cenários simulados nos quais o armazenamento das regiões Sudeste e/ou Sul ficou abaixo das respectivas metas, mas não houve racionamento de energia. Estes cenários requerem atenção uma vez que, em alguns deles, pode ocorrer problemas de suprimento à demanda de ponta.");
    md:add("- \"Racionamento\" (Vermelho): % dos cenários simulados nos quais foi necessário corte de consumo de energia, indicando a necessidade de um racionamento.");
dashboard2:push(md);
dashboard2:push("\n");
md = Markdown();
md:add("Além da probabilidade, apresentamos também uma medida da severidade do racionamento: valor esperado do corte de carga nestes cenários (isto é, condicionado aos eventos de corte de carga) e expresso como o corte constante de uma percentagem das demandas do Sudeste e Sul de setembro a novembro (em outras palavras, o simulador operativo só permite cortes de carga a partir de setembro).");
md:add("\n");
dashboard2:push(md);

local chart2_3 = Chart("Análise de suprimento");
chart2_3:add_pie(enearm_final_risk_level0_SE_or_SU_pie:rename_agents({"Normal"}):round(number_of_digits_round), {color="green", yMax="100"});
chart2_3:add_pie(enearm_final_risk_level1_SE_or_SU_pie:rename_agents({"Atenção"}):round(number_of_digits_round), {color="yellow"});
chart2_3:add_pie(enearm_final_risk_level2_SE_or_SU_pie:rename_agents({"Racionamento"}):round(number_of_digits_round), {color="red"});
dashboard2:push(chart2_3);

-- dashboard2:push("**Normal**: Sudeste acima de 10% e Sul acima de 30%");
-- dashboard2:push("**Atenção**: Sudeste abaixo de 10% ou Sul abaixo de 30%. Sem deficit.");
-- dashboard2:push("**Racionamento**: Deficit.");

dashboard2:push("Probabilidade do armazenamento do Sudeste ficar entre 10% e 15% e não ter deficit (incluído nos cenários normais): **" .. string.format("%.1f", (enearm_final_risk_level0_SE_or_SU-enearm_final_risk_level1_SE_or_SU):to_list()[1]) .. "%**");

local chart2_4 = Chart("Deficit - histograma");
local violation_minimum_value = 0.1;
local number_violations = ifelse(deficit_percentual:gt(violation_minimum_value), 1, 0):aggregate_scenarios(BY_SUM()):to_list()[1];
local deficit_percentual = ifelse(deficit_percentual:gt(violation_minimum_value), deficit_percentual, 0);
local media_violacoes = deficit_percentual:aggregate_scenarios(BY_SUM()) / number_violations;
local maxima_violacao = deficit_percentual:aggregate_scenarios(BY_MAX());

if is_debug then
    deficit_percentual:save("Deficit - histograma");
    media_violacoes:save("media_deficit");
    maxima_violacao:save("maximo_deficit");
end

dashboard2:push("Violação média: **" .. string.format("%.1f", media_violacoes:to_list()[1]) .. "%** da demanda");
dashboard2:push("Violação média é a média condicional do deficit dos sobre a demanda dos últimos 3 estágios (Setembro, Outubro e Novembro) dado que ocorreu um cenário de racionamento (vermelho).");
-- dashboard2:push("\n");
if is_complete then
    dashboard2:push("Violação máxima: **" .. string.format("%.1f", maxima_violacao:to_list()[1]) .. "%** da demanda"); 
    chart2_4:add_histogram(deficit_percentual, {color="#d3d3d3", xtickPositions="[0, 20, 40, 60, 80, 100]"}); -- grey
    dashboard2:push(chart2_4);
end

if is_complete then
    local chart2_5 = Chart("Demanda residual");
    chart2_5 = add_percentile_layers(chart2_5, demanda_residual, "GWm");
    dashboard2:push(chart2_5);

    local chart = Chart("Demanda residual - histograma");
    chart:add_histogram(demanda_residual:aggregate_stages(BY_SUM()), {yUnit="GWm", color="#d3d3d3", xtickPositions="[0, 20, 40, 60, 80, 100]"});
    dashboard2:push(chart);
end

md = Markdown();
md:add("\n\n")
md:add("## Déficit por etapa");
md:add("Por fim, apresentamos a média do déficit para cada mês no conjunto de 1200 cenários simulados pela PSR (ou selecionado pelo usuário). Apresentamos também o intervalo de confiança de 90%, no qual a linha inferior corresponde ao quantil de 5% e a linha superior corresponde ao quantil de 95%. ");
md:add("Observação: Se menos de 5% dos cenários tiverem déficit, o intervalor de confiança de 90% vai ser igual a zero");
md:add("\n\n");
dashboard2:push(md);

local chart2_6 = Chart("Deficit");
deficit_stages_chart2_6 = ifelse(deficit_stages:convert("GW"):gt(0.1), deficit_stages:convert("GW"), 0.0):round(number_of_digits_round);
chart2_6 = add_percentile_layers(chart2_6, deficit_stages_chart2_6, "GWm", true);
dashboard2:push(chart2_6);

if is_complete then
    local chart2_7 = Chart("Enegergia Armazenada - Sudeste");
    chart2_7 = add_percentile_layers(chart2_7, enearm_SE_ini_stage, false);

    local chart2_8 = Chart("Enegergia Armazenada - Sul");
    chart2_8 = add_percentile_layers(chart2_8, enearm_SU_ini_stage, false);
    dashboard2:push({chart2_7, chart2_8});
end
-- local chart2_7 = Chart("Enegergia Armazenada - Sudeste");
-- chart2_7 = add_percentile_layers(chart2_7, enearm_SE_stages, false);
-- local chart2_8 = Chart("Enegergia Armazenada - Sul");
-- chart2_8 = add_percentile_layers(chart2_8, enearm_SU_stages, false);
-- dashboard2:push(chart2_7);
-- dashboard2:push(chart2_8);
-- dashboard2:push({chart2_7, chart2_8});

if is_debug then
    demanda_residual:aggregate_stages(BY_SUM()):save("demanda_residual_histogram_data");
end

-- inflows
local dashboard7 = Dashboard("Hidrologia (ENA)");

local md = Markdown();
md:add("# Hidrologia ENA");
md:add("## Energia Natural Afluente das regiões Sul e Sudeste");
md:add("Nesta primeira aba apresentamos os dados da Energia Natural Afluente (ENA) dos subsistemas Sul e Sudeste/Centro-Oeste. Para ambos apresentamos dados históricos:");
    md:add("- \"Histórico 2020\": a ENA realizada em 2020");
    md:add("- \"Histórico 2021\": a ENA realizada até Julho para 2021");
    md:add("- \"MLT\": a média de longo termo");
md:add("\n");
md:add("E dados utilizados nas simulações probabilísticas da PSR:");
    md:add("- \"Média\": média dos cenários gerados pela PSR com modelo Time Series Lab (TSL)");
    md:add("- \"Intervalo de confiança de 90%\": Intervalo de confiança de 90% dos cenários gerados pelo TSL da PSR. A linha inferior representa o quantil de 5% e a linha superior representar o quantil de 95%.");
md:add("\n");
dashboard7:push(md);
dashboard7:push("\n");

local chart7_2 = Chart("Energia natural afluente - Sudeste e Centro-Oeste");

-- local inflow_energia_se_historico_2020_09 = Inflow_energia_historico_2020:select_agents({"Histórico 2020 - SE"}):rename_agents({"Histórico 2020 - SE x 90%"}) * 0.9; -- 2020 * 0.9
-- chart7_2:add_line(inflow_energia_se_historico_2020_09, {yUnit="GWm"});

local inflow_energia_se_historico_2020 = Inflow_energia_historico_2020:select_agents({"Histórico 2020 - SE"}):rename_agents({"Histórico 2020"}); -- 2020
chart7_2:add_line(inflow_energia_se_historico_2020, {yUnit="GWm"});

local inflow_energia_se_historico_2021 = Inflow_energia_historico_2021:select_agents({"Histórico 2021 - SE"}):rename_agents({"Histórico 2021"});
chart7_2:add_line(inflow_energia_se_historico_2021, {yUnit="GWm"});

local inflow_energia_mlt_se = Inflow_energia_mlt:select_agents({"SE-MLT"}):rename_agents({"MLT"});
chart7_2:add_line(inflow_energia_mlt_se, {yUnit="GWm"});

local inflow_energia_se = Inflow_energia:select_agents({"SUDESTE"});
chart7_2 = add_percentile_layers(chart7_2, inflow_energia_se, "GWm");
dashboard7:push(chart7_2);

if is_debug then
    inflow_energia_se:save("inflow_energia_se");
    inflow_energia_mlt_se:save("inflow_energia_mlt_se");
    inflow_energia_se_historico_2021:save("Inflow_energia_se_historico_2021");
    inflow_energia_se_historico_2020_09:save("Inflow_energia_se_historico_2020_09");
end

local chart7_3 = Chart("Energia natural afluente - Sul");
-- local inflow_energia_su_historico_2020_09 = Inflow_energia_historico_2020:select_agents({"Histórico 2020 - SU"}):rename_agents({"Histórico 2020 - SU x 90%"}) * 0.9; -- 2020 * 0.9
-- chart7_3:add_line(inflow_energia_su_historico_2020_09, {yUnit="GWm"});

local inflow_energia_su_historico_2020 = Inflow_energia_historico_2020:select_agents({"Histórico 2020 - SU"}):rename_agents({"Histórico 2020"}); -- 2020
chart7_3:add_line(inflow_energia_su_historico_2020, {yUnit="GWm"});

local inflow_energia_su_historico_2021 = Inflow_energia_historico_2021:select_agents({"Histórico 2021 - SU"}):rename_agents({"Histórico 2021"});
chart7_3:add_line(inflow_energia_su_historico_2021, {yUnit="GWm"});

local inflow_energia_mlt_su = Inflow_energia_mlt:select_agents({"SU-MLT"}):rename_agents({"MLT"});
chart7_3:add_line(inflow_energia_mlt_su, {yUnit="GWm"})

local inflow_energia_su = Inflow_energia:select_agents({"SUL"});
chart7_3 = add_percentile_layers(chart7_3, inflow_energia_su, "GWm");
dashboard7:push(chart7_3);

if is_debug then
    inflow_energia_su_historico_2020_09:save("inflow_energia_su_historico_2020_09");
    inflow_energia_su_historico_2021:save("inflow_energia_su_historico_2021");
    inflow_energia_mlt_su:save("inflow_energia_mlt_su");
    inflow_energia_su:save("inflow_energia_su");
end

local media_mlt_horizonte = Inflow_energia_mlt:convert("GW"):select_stages(11-last_stage+1,11):aggregate_stages(BY_AVERAGE()):reset_stages():aggregate_agents(BY_SUM(), "SE+SU");
-- media_mlt_horizonte = 34.95 GWm

local md = Markdown();
md:add("\n");
md:add("A seguir apresentamos um histograma com os cenários de Energia Natural Afluente (ENA), soma de Sul e Sudeste para os meses em análise (Julho a Novembro). Por simplicidade apresentamos valores de ENA em percentual da média de longo termo (MLT), ou seja, um valor de 120 no eixo horizontal representa uma ENA de 120% da MLT.");
md:add("\n");
dashboard7:push(md);

local chart7_4 = Chart("Energia natural afluente - histograma");
-- xLine = ena media de 2020 entre Agosto e novembro em GWm
chart7_4:add_histogram((Inflow_energia:select_stages(1,last_stage):convert("GW"):aggregate_stages(BY_AVERAGE()):select_agents({"SUDESTE", "SUL"}):aggregate_agents(BY_SUM(), "SE+SU")/media_mlt_horizonte):convert("%"), {yUnit = "Percentual (%) da MLT"});
dashboard7:push(chart7_4);
(Inflow_energia:select_stages(1,last_stage):convert("GW"):aggregate_stages(BY_AVERAGE()):select_agents({"SUDESTE", "SUL"}):aggregate_agents(BY_SUM(), "SE+SU")/media_mlt_horizonte):convert("%"):save("ena_historgram_data");

local ena_media_horizonte_2020_relativo_mlt = ena_de_2020_horizonte_GWm / media_mlt_horizonte:to_list()[1] * 100; -- %.
local Inflow_energia_2021 = (Inflow_energia:select_stages(1,last_stage):convert("GW"):aggregate_stages(BY_AVERAGE()):select_agents({"SUDESTE", "SUL"}):aggregate_agents(BY_SUM(), "SE+SU")/media_mlt_horizonte):convert("%");
local inflows_acima_ena_2020 = ifelse(Inflow_energia_2021:gt(ena_media_horizonte_2020_relativo_mlt), 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%");
dashboard7:push("Probabilidade da ENA acumulada entre agosto e novembro de 2021 superar correspondente valor do ano de 2020: **" .. string.format("%.1f", inflows_acima_ena_2020:to_list()[1]) .. "%**");
dashboard7:push("MLT da ENA, média do horizonte de Agosto a Novembro: **" .. string.format("%.1f", media_mlt_horizonte:to_list()[1]) .. "** GWm");

local dashboard8 = Dashboard("Hidrologia (usinas)");
--inflow_min_selected
--inflow_2021janjun_selected.csv

local md = Markdown();
md:add("# Hidrologia (usinas)");
md:add("## Vazão de usinas selecionadas");
md:add("Apresentamos o mesmo template de gráfico para usinas que merecem atenção especial selecionadas pela PSR.");
md:add("Para cada usina apresentamos dados:");
    md:add("- \"Vazão mínima\": para cada mês apresentamos a menor vazão ocorrida desde 1931");
    md:add("- \"2021\": Vazão realizada até Junho de 2021");
    md:add("- \"Defluência mínima\": Restrição de defluência apresentada no PMO de Julho");
dashboard8:push(md);
local md = Markdown();
md:add("E também apresentamos um resumo dos cenários gerados pelo modelo Time Series Lab (TSL) da PSR utilizados nas demais análises.");
    md:add("- \"Intervalo de 90% das vazões naturais\": Sobra com linha inferior representando o quantil de 5% e linha superior representando o quantil de 95%.");
    md:add("- \"Vazão média\": média dos cenários simulados para cada mês.");
dashboard8:push(md);

local minimum_outflow = hydro.min_total_outflow;
local minimum_outflow_cronologico = hydro.min_total_outflow_modification;
local minimum_outflow_valido = max(minimum_outflow, minimum_outflow_cronologico):select_stages(1,last_stage);
local minimum_turbining = hydro.qmin:select_stages(1,last_stage);
local minimum_outflow_valido = max(minimum_outflow_valido, minimum_turbining);

local irrigation = hydro.irrigation:select_stages(1,last_stage);
local agua_outros_usos = minimum_outflow_valido + irrigation;

-- tem que usar generic neste graf para não assumir que temos dados para todas as hidros
-- dados são para um subconjunto das hidros
local inflow_min_selected = generic:load("inflow_min_selected");
local inflow_2021janjun_selected = generic:load("inflow_2021janjun_selected");
local inflow_agua = generic:load("vazao_natural"):select_stages(1,last_stage)

local md_tabela_violacoes = Markdown();
md_tabela_violacoes:add("Usina|Mínimo Histórico (m3/s) | Uso múltiplo da água (m3/s) | Probabilidade Violação (%) | Violação Média (%) | Violação Máxima (%)");
md_tabela_violacoes:add(":-|-:|-:|-:|-:|-:");

local inflow_min_selected_agents = {};
for i = 1,inflow_min_selected:agents_size(),1 do
    table.insert(inflow_min_selected_agents, inflow_min_selected:agent(i));
end
table.sort(inflow_min_selected_agents)

for _,agent in ipairs(inflow_min_selected_agents) do
    local total_violation_percentual_agent = total_violation_percentual:select_agents({agent});
    if is_debug then total_violation_percentual_agent:save("total_violation_percentual_" .. agent); end

    dashboard8:push("###  " .. agent);

    local violation_minimum_value = 0.1; -- em %
    local violations = ifelse(total_violation_percentual_agent:gt(violation_minimum_value), 1, 0);
    local violations_values = ifelse(total_violation_percentual_agent:gt(violation_minimum_value), total_violation_percentual_agent, 0.0);
    number_violations = violations:aggregate_scenarios(BY_SUM()):to_list()[1];
    -- dashboard8:push("Probabilidade de violar: **" .. string.format("%.1f", tostring((number_violations/1200) * 100)) .. "%**");
    if number_violations > 0 then
        media_violacoes = violations_values:aggregate_scenarios(BY_SUM()) / number_violations;
        maxima_violacao = violations_values:aggregate_scenarios(BY_MAX());
        
        -- if is_debug then media_violacoes:save("media_" .. agent); maxima_violacao:save("maximo_" .. agent); end

        -- dashboard8:push("Violação média: **" .. string.format("%.1f", media_violacoes:to_list()[1]) .. " %** da defluência mínima");
        -- dashboard8:push("Violação máxima: **" .. string.format("%.1f", maxima_violacao:to_list()[1]) .. " %** da defluência mínima"); 
    else
        -- dashboard8:push("Violação média: **0.0 %** da defluência mínima");
        -- dashboard8:push("Violação máxima: **0.0 %** da defluência mínima");
    end
    -- chart
    local inflow_min_selected_agent = inflow_min_selected:select_stages(1,11):select_agents({agent}):rename_agents({"Vazão mínima"});
    local sum_min_inflow_horizon = inflow_min_selected_agent:select_stages(8,11):aggregate_stages(BY_AVERAGE()):to_list()[1];
    local inflow_2021janjun_selected_agent = inflow_2021janjun_selected:select_agents({agent}):rename_agents({"2021"});
    local agua_outros_usos_agent = agua_outros_usos:select_agents({agent}):rename_agents({"Defluência mínima"});
    local sum_agua_outros_usos = agua_outros_usos_agent:aggregate_stages(BY_AVERAGE()):to_list()[1];
    local p_min = inflow_agua:select_agents({agent}):aggregate_scenarios(BY_PERCENTILE(5)):rename_agents({"Intervalo de 90% das vazões naturais"});
    local p_max = inflow_agua:select_agents({agent}):aggregate_scenarios(BY_PERCENTILE(95)):rename_agents({""});   
    local avg = inflow_agua:select_agents({agent}):aggregate_scenarios(BY_AVERAGE()):rename_agents({"Vazão média"});
    
    local chart8_i = Chart("");
    chart8_i:add_line(inflow_min_selected_agent);
    chart8_i:add_line(inflow_2021janjun_selected_agent);
    chart8_i:add_line(agua_outros_usos_agent);
    chart8_i:add_area_range(p_min, p_max, {color="#77a1e5"});
    chart8_i:add_line(avg, {color="#000000"});
    dashboard8:push(chart8_i);
    
    -- historgrama
    if is_complete then
        local chart8_i2 = Chart("Histograma de violações de defluência mínima");
        chart8_i2:add_histogram(total_violation_percentual_agent, {color="#d3d3d3", yUnit="% da defluência mínima não atendida", xtickPositions="[0, 20, 40, 60, 80, 100]"}); -- grey
        dashboard8:push(chart8_i2);
    end

    dashboard8:push("---");

    -- tabela
    if number_violations > 0 then
        md_tabela_violacoes:add(agent .. " | " .. string.format("%.1f", tostring(sum_min_inflow_horizon)) .. " | " .. string.format("%.1f", tostring(sum_agua_outros_usos)) .. " | " .. string.format("%.1f", tostring((number_violations/1200) * 100)) .. " | " .. string.format("%.1f", tostring(media_violacoes:to_list()[1]))  .. " | " .. string.format("%.1f", tostring(maxima_violacao:to_list()[1])));
    else
        md_tabela_violacoes:add(agent .. " | " .. string.format("%.1f", tostring(sum_min_inflow_horizon)) .. " | " .. string.format("%.1f", tostring(sum_agua_outros_usos)) .. " | " .. string.format("%.1f", tostring((number_violations/1200) * 100)) .. " | " .. string.format("%.1f", 0.0)  .. " | " .. string.format("%.1f", 0.0));
    end
end

local dashboard10 = Dashboard("Violações");

local md = Markdown();
md:add("# Violações");
md:add("## Violações nas restrições de uso múltiplo da água");
md:add("Nesta seção apresentamos uma tabela com o resumo dos resultados do nosso Simulador de Usos Múltiplos da água (SUM), ver Energy Report de Julho.");
md:add("Assim como na seção anterior, consideramos um subconjunto das usinas do PMO para avaliar em detalhe.");
md:add("Na tabela a seguir apresentamos cinco valores para cada uma das usinas selecionadas:");
    md:add("- \"Mínimo Histórico (m3/s)\": Média no horizonte para menor vazão observada no histórico de dados");
    md:add("- \"Uso múltiplo da água\": Média no horizonte do somatório das restrições de Irrigação e de defluência mínima que incluem uso consuntivo, restrições de navegabilidade...");
    md:add("- \"Probabilidade Violação\": percentual dos 1200 cenários de vazão onde houve violação das restrições. Observe que o modelo que tem como função objetivo minimizar violações e contem apenas restrições de balanço hídrico.");
    md:add("- \"Violação Média\": Média das violações condicionada aos cenários onde houve violação em porcentagem da restrição de uso múltiplo.");
    md:add("- \"Defluência mínima\":  Média no horizonte das restrição de defluência apresentada no PMO de Julho");
    md:add("- \"Violação Máxima\":  Média no horizonte da maior violação observada nas simulações em porcentagem da restrição de uso múltiplo");
    md:add("\n");
dashboard10:push(md);
dashboard10:push("\n");

dashboard10:push(md_tabela_violacoes);
dashboard10:push("\n");
-- dashboard10:push("Obs: Aimores tem bastante violação mesmo com o uso múltiplo da água ser abaixo do mínimo histórico." ..
--     "Isso pode ser explicado porque a usina a jusante dela - Mascarenhas - tem um aumento de 120m3/s na defluência mínima." ..
--     " Isto obriga Aimores turbinar ou verter mais.");
--     dashboard10:push("---");


if is_complete then
    local hydro_selected_agents = hydro.vmax:select_agents(hydro.vmax:gt(hydro.vmin):select_stages(last_stage)):agents();
    table.sort(inflow_min_selected_agents);
    local md = Markdown();
    md:add("Usina | Volume morto (%) | volume  útil (hm3)");
    md:add(":-|-:|-:");
    for _,agent in ipairs(hydro_selected_agents) do
        local vol_util = (hydro.vmax-hydro.vmin):select_agents({agent});
        local dead_storage = (max(0.0, (max(hydro.alert_storage,hydro.vmin_chronological) - hydro.vmin)):select_agents({agent})/vol_util):convert("%");
        md:add(agent .. " | " .. string.format("%.1f", dead_storage:to_list()[1]) .. " | " .. string.format("%.1f", vol_util:to_list()[1]));
    end
    dashboard10:push(md);
end


-- cenarios de atencao na energia serão usados para a analise de potenica
cenarios_potencia = {};
local numero_cenarios_potencia = 0;
cenarios_atencao_list = cenarios_atencao:to_int_list();
for cenario, value in ipairs( cenarios_atencao_list ) do
    if value == 1 then
        table.insert(cenarios_potencia, cenario);
        numero_cenarios_potencia = numero_cenarios_potencia + 1;
    end
end

cenarios_vermelhos= {};
local numero_cenarios_vermelhos = 0;
cenarios_vermelhos_list = has_deficit:to_int_list();
for cenario, value in ipairs( cenarios_vermelhos_list ) do
    if value == 1 then
        table.insert(cenarios_vermelhos, cenario);
        numero_cenarios_vermelhos = numero_cenarios_vermelhos + 1;
    end
end

local dashboard9 = Dashboard("Potência");
if bool_potencia then
    local md = Markdown();
    md:add("# Potência");
    md:add("Nesta última sequência de análises apresentamos um detalhamento da situação do suprimento de potência considerando as premissas escolhidas na interface.");
    md:add("Avaliamos 3 métricas principais:");
        md:add("- Risco de problemas de suprimento de potência");
        md:add("- Frequência de problemas de suprimento de ponta");
        md:add("- Severidade do corte de carga ao longo do dia");
    dashboard9:push(md);
    local md = Markdown();
    md:add("É fundamental lembrar que as **análises a seguir são condicionadas aos cenários de Atenção** (amarelos). Ou seja, apenas um subconjunto dos 1200 cenários considerados pela PSR é levado em conta para calcular as métricas que apresentaremos. Note que os cenários Normais (verdes) têm água suficiente nos reservatórios para manter controlabilidade e nos cenários Racionamento (vermelhos), já precisam de medidas de controle agressivas.");
    md:add("Tivemos um percentual de " .. string.format("%.1f", enearm_final_risk_level1_SE_or_SU_pie:to_list()[1]) .. "% de casos de atenção, ou seja, " .. tostring(numero_cenarios_potencia) .. " cenários que merecem análise detalhada de potência.");
    md:add("Lembre-se que tivemos um percentual de " .. string.format("%.1f", enearm_final_risk_level2_SE_or_SU_pie:to_list()[1]) .. "% (" .. tostring(numero_cenarios_vermelhos) .. " cenários) de cenários com déficit, ou seja, nesses casos já existe corte de carga, de modo que não é necessária análise mais detalhada para eles.");
    md:add("Assim como no caso do balanço de energia, o resultado do balanço de oferta × demanda horário é classificado em três grupos:");
        md:add("- \"Normal\" (Azul): oferta total excede demanda + reserva -> situação operativa normal");
        md:add("- \"Violação da reserva\" (Laranja): oferta total entre demanda e demanda + reserva -> situação operativa de alerta");
        md:add("- \"Corte de carga\" (Roxo): oferta total inferior à demanda -> corte de carga (blecaute rotativo)");
        -- md:add("O RiskBoard produz três índices de suprimento de potência:");
    -- md:add("A análise de potência é **condicional** a acontecer algum **cenário de atenção** na análise de suprimento de energia (" .. string.format("%.1f", enearm_final_risk_level1_SE_or_SU_pie:to_list()[1]) .. "% dos cenários)");
    -- dashboard2:push("Violação média: **" .. string.format("%.1f", enearm_final_risk_level1_SE_or_SU_pie:to_list()[1]) .. "%** da demanda");
    dashboard9:push(md);
    local md = Markdown();
    md:add("Repetimos aqui comentários sobre as premissas do dashboard, feito no Energy Report de Julho.");
    md:add("A diferença entre as hidrelétricas com reservatório e fio d'água em termos de atendimento à ponta é que para a maioria das usinas a fio d’água não é possível produzir a potência máxima quando necessário. Foi então aplicado um fator de modulação sobre a geração média de cada usina a fio d'água em cada cenário e cada mês para representar sua capacidade efetiva de contribuir para o atendimento à ponta. Este fator de modulação foi estimado pela PSR de forma empírica a partir de resultados de simulações operativas horárias." ..
        "Um tema relevante para as análises de suprimento de ponta é a hipótese de que as hidrelétricas com reservatório podem modular livremente sua operação, isto é, produzir a potência máxima disponível quando necessário (naturalmente, ajustadas pelo nível do reservatório e equipamentos em manutenção). As informações públicas sobre estas usinas não indicam que há restrições em sua flexibilidade operativa. No entanto, se estas restrições existirem para hidrelétricas de porte significativo, o risco de suprimento de potência pode ser maior do que o apresentado a seguir." ..
        "Além da incerteza sobre a flexibilidade de modulação das hidrelétricas, não nos parece claro como a Geração Distribuída é representada nas previsões de demanda oficiais nos estudos de planejamento da operação. Como grande parte dessa geração é solar, os balanços de energia e potência podem ser bastante influenciados pelo ritmo do seu crescimento. A PSR está analisando ambos os temas.")
    md:add("\n\n");
    
    dashboard9:push(md);
end;

if bool_potencia and numero_cenarios_potencia > 0 then
    demand_hr = system:load("demand_hr"):select_stages(1,last_stage):convert("GW"):select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "SE + SU");
    if bool_demanda_reduzida then
        demand_hr = (1 - input_demanda_reduzida) * demand_hr;
    end
    if bool_demanda_extra then
        demand_hr = (1 + input_demanda_extra) * demand_hr;
    end
    demand_hr:save("demand_hr_tmp", {csv=true})

    
    gergnd_hr = renewable:load("gergnd_hr"):select_stages(1,last_stage):aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "SE + SU");
    if tipo_sensib_gnd == 2 then
        gergnd_hr = gergnd_hr:select_scenarios({cenario_renovavel});
    else
        gergnd_hr = gergnd_hr:select_scenarios(cenarios_potencia);
    end

    -- hydro max_power computation
    -- hydro_max_power = hydro:load("potencia_maxima_volume_minimo_minimorum");

    -- hydro_max_power_disponivel  = hydro_max_power * (100-hydro_disponibilidade);
    waveguide_power = hydro:load("potencia_maxima_waveguide");
    local stages = waveguide_power:stages();
    waveguide_volumes = hydro:load("waveguide"):select_stages(1,stages):reset_stages():aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"});
    waveguides_storageenergy = hydro:load("storageenergy_waveguide"):select_stages(1,stages):reset_stages():aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"}):convert("GWh");
    gerhid_power_fio_dagua = ifelse(hydro.vmax:gt(hydro.vmin), 0, hydro:load(is_sddp and "gerhid" or "gerhid_KTT", true):select_scenarios(cenarios_potencia):convert("GW"):aggregate_blocks(BY_AVERAGE()):select_stages(1,last_stage)):aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"});
    -- waveguide_power = ifelse(hydro.vmax:gt(hydro.vmin), waveguide_power, 0); -- diminui potencia disponivel das fio d'água
    waveguide_power = ifelse(hydro.vmax:gt(hydro.vmin), waveguide_power, waveguide_power*0.55); -- diminui potencia disponivel das fio d'água
    waveguide_power = waveguide_power:aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"});
    -- waveguide_power = hydro:load("potencia_maxima_waveguide"):aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"});
    waveguide_volumes = waveguide_volumes:save_and_load("waveguide_volumes_system", {tmp = true, csv = false});
    waveguide_power = waveguide_power:save_and_load("waveguide_power_system", {tmp = false, csv = true});
    -- waveguide_power:save("waveguide_energy_system", {csv = true});
    -- enearm_final = enearm_SE:convert("GW"):select_scenarios(cenarios_potencia);
    -- enearm_SU_ini_stage = concatenate(enearm_SU_ini_stage,
    --                             enearm_SE_ini_stage);
    enearm_final =  concatenate(enearm_SU_stages,
                                enearm_SE_stages):select_scenarios(cenarios_potencia);
    hydro_max_power = interpolate_stages(enearm_final, waveguides_storageenergy, waveguide_power:convert("GWh")):convert("GW");
    -- gerhid_power_fio_dagua:save("gerhid_power_fio_dagua", {tmp = false, csv = true});
    -- hydro_max_power = hydro_max_power + gerhid_power_fio_dagua;

    --
    -- hydro_disponibilidade = hydro.ih;
    -- (100-hydro_disponibilidade):save("cache_hydro_disponibilidade", {tmp = false, csv = true});
    --

    hydro_max_power_disponivel  = hydro_max_power * (1-0.1);
    -- hydro_max_power_disponivel = hydro_max_power_disponivel:aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "SE + SU");
    -- hydro_max_power = hydro_max_power:aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "SE + SU");
    hydro_max_power_disponivel = hydro_max_power_disponivel:select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "SE + SU");
    hydro_max_power = hydro_max_power:select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "SE + SU");
    hydro_max_power = hydro_max_power:save_and_load("hydro_max_power", {tmp = false, csv = true});

    -- pothid = hydro:load("pothid"):aggregate_agents(BY_SUM(), Collection.SYSTEM):select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "SE + SU");
    gergnd_hr = gergnd_hr:convert("GW"):save_and_load("gergnd_hr_temp", {tmp = false, csv = true});
    thermal_generation_hr = thermal_generation_block:convert("GW"):to_hour(BY_REPEATING()):save_and_load("thermal_generation_hr_temp", {tmp = false, csv = true});
    capint2_SE_hr = capint2_SE_block:convert("GW"):to_hour(BY_REPEATING()):save_and_load("capint2_SE_hr_temp", {tmp = false, csv = true});
    hydro_max_power_hr =  hydro_max_power_disponivel:convert("GW"):save_and_load("hydro_max_power_hr_temp", {tmp = false, csv = true});
    power_hr = gergnd_hr + thermal_generation_hr + capint2_SE_hr + hydro_max_power_hr;
    if bool_int_extra then
        power_hr = power_hr + capint2_SE_extra_block:convert("GW"):to_hour(BY_REPEATING());
    end
    if bool_oferta_extra then
        oferta_extra = generic:load("extra_generation", true):convert("GW");
        -- oferta_extra = generic:load("extra_generation_2", true):convert("GW");
        power_hr = power_hr + oferta_extra:aggregate_agents(BY_SUM(), "SE + SU");
    end
    if bool_operacao_limitada_itaipu then
        power_hr = max(0, power_hr - perda_itaipu_e_extras);
    end
    power_hr = power_hr:save_and_load("cache_power_hr", {tmp = true, csv = false});
    mismatch_power = (demand_hr - power_hr):save_and_load("cache_mismatch_power", {tmp = true, csv = false});
    criterio_severidade_de_apagao = 1.05;
    mismatch_power_reserva = (demand_hr * criterio_severidade_de_apagao - power_hr):save_and_load("cache_mismatch_power_reserva", {tmp = true, csv = false});
    apagao_severo = ifelse(mismatch_power:gt(0), 1, 0):aggregate_blocks(BY_AVERAGE()):convert("%"):round(number_of_digits_round);
    apagao_reserva = ifelse(mismatch_power_reserva:gt(0), 1, 0):aggregate_blocks(BY_AVERAGE()):convert("%"):round(number_of_digits_round);
    apagao_reserva = apagao_reserva - apagao_severo; -- quando acontece apagao severo, também acontece apagão na reserva, mas não queremos dupla contagem
    percentual_threshold = 1 -- %
    risco_apagao_reserva = ifelse(apagao_reserva:gt(percentual_threshold), 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):round(number_of_digits_round); -- maior que percentual_threshold %
    risco_apagao_severo = ifelse(apagao_severo:gt(percentual_threshold), 1, 0):aggregate_scenarios(BY_AVERAGE()):convert("%"):round(number_of_digits_round); -- maior que percentual_threshold %
    risco_apagao_reserva = risco_apagao_reserva - risco_apagao_severo;
    sem_risco_apagao = 100 - (risco_apagao_reserva+risco_apagao_severo);

    local md = Markdown();
    md:add("## Risco de problemas de suprimento");
    -- md:add("Porcentagem (%) dos cenários em que não houve nenhuma hora classificada como laranja ou roxo; % dos cenários em que houve ao menos 1% das horas classificadas como laranja, porém nenhuma hora classificada como roxo; e % dos cenários em que houve ao menos 1% das hora classificada como roxo.");
    md:add("- \"Normal\" (Azul): Porcentagem dos cenários em que a oferta ficou maior que a demanda em pelo menos 99% das horas");
    md:add("- \"Violação da reserva\" (Laranja): Porcentagem dos cenários em que a oferta ficou entre que a demanda e a reserva pelo menos 1% das horas e não houve corte de carga");
    md:add("- \"Corte de carga\" (Roxo): Porcentagem dos cenários em que a oferta ficou maior que a demanda mais a reserva pelo menos 1% das horas");
    dashboard9:push(md);

    local chart9_1 = Chart("Suprimento de ponta");
    chart9_1:add_column_stacking(risco_apagao_severo:rename_agents({"Corte de carga"}), {color="purple", yMax="100"});
    chart9_1:add_column_stacking(risco_apagao_reserva:rename_agents({"Violação da reserva"}), {color="orange"});
    chart9_1:add_column_stacking(sem_risco_apagao:rename_agents({"Normal"}), {color="blue"});
    dashboard9:push(chart9_1);

    -- apagar ?
    -- apagao_severo_dia = ifelse(mismatch_power:gt(0), 1, 0):select_stages(3):reshape_stages(Profile.DAILY):aggregate_blocks(BY_MAX()):aggregate_stages(BY_SUM());
    -- apagao_reserva_dia = ifelse(mismatch_power_reserva:gt(0), 1, 0):select_stages(3):reshape_stages(Profile.DAILY):aggregate_blocks(BY_MAX()):aggregate_stages(BY_SUM());
    -- apagao_severo_dia = ifelse(apagao_severo_dia:gt(0), 1, 0):aggregate_scenarios(BY_AVERAGE());
    -- apagao_reserva_dia = ifelse(apagao_reserva_dia:gt(0), 1, 0):aggregate_scenarios(BY_AVERAGE());
    -- apagao_reserva_dia = apagao_reserva_dia - apagao_severo_dia; -- quando acontece apagao severo, também acontece apagão na reserva, mas não queremos dupla contagem
    -- -- sem_risco_apagao_dia = 100 - (apagao_reserva_dia+apagao_severo_dia);
    -- local chart9_2 = Chart("Risco apagao diário");
    -- chart9_2:add_column_stacking(apagao_severo_dia, {color="red"});
    -- chart9_2:add_column_stacking(apagao_reserva_dia, {color="yellow"});
    -- -- chart9_2:add_column_stacking(sem_risco_apagao_dia, {color="green"});
    -- dashboard9:push(chart9_2);

    local md = Markdown();
    md:add("## Frequência de problemas de suprimento de ponta");
    -- md:add("Porcentagem (%) dos dias do mês em que em pelo menos uma hora houve problemas de reserva, porém não houve corte de carga;% dos dias em que em pelo menos uma hora houve corte de carga.");
    -- dashboard9:push(md);
    -- md:add("Porcentagem (%) dos cenários em que não houve nenhuma hora classificada como laranja ou roxo; % dos cenários em que houve ao menos 1% das horas classificadas como laranja, porém nenhuma hora classificada como roxo; e % dos cenários em que houve ao menos 1% das hora classificada como roxo.");
    md:add("- \"Normal\" (Azul): Frequenência média dos cenários em que a oferta ficou maior que a demanda");
    md:add("- \"Violação da reserva\" (Laranja): Frequenência média  dos cenários em que a oferta ficou entre que a demanda e a reserva não houve corte de carga");
    md:add("- \"Corte de carga\" (Roxo): Frequenência média dos cenários em que a oferta ficou maior que a demanda mais a reserva");
    dashboard9:push(md);

    local chart9_2 = Chart("Blecaute - frequência");
    local apagao_severo_dia = ifelse(mismatch_power:gt(0), 1, 0);
    local apagao_reserva_dia = ifelse(mismatch_power_reserva:gt(0), 1, 0);
    -- local stages = apagao_severo_dia:stages();
    -- apagao_reserva_dia:save("tmp_apagao_reserva_dia", {tmp = false, csv = false});
    -- for stage = 1,stages,1 do
    --     local month = apagao_severo_dia:month(stage);
    --     if false then
    --         tmp_severo = concatenate_stages(tmp_severo, apagao_severo_dia:select_stages(stage):reshape_stages(Profile.DAILY):aggregate_blocks(BY_MAX()):aggregate_stages(BY_AVERAGE(), Profile.PER_MONTH):aggregate_scenarios(BY_AVERAGE()));
    --         tmp_reserva = concatenate_stages(tmp_reserva, apagao_reserva_dia:select_stages(stage):reshape_stages(Profile.DAILY):aggregate_blocks(BY_MAX()):aggregate_stages(BY_AVERAGE(), Profile.PER_MONTH):aggregate_scenarios(BY_AVERAGE()));
    --     else
    --         tmp_severo = apagao_severo_dia:select_stages(stage):reshape_stages(Profile.DAILY):aggregate_blocks(BY_MAX()):aggregate_stages(BY_AVERAGE(), Profile.PER_MONTH):aggregate_scenarios(BY_AVERAGE());
    --         tmp_reserva = apagao_reserva_dia:select_stages(stage):reshape_stages(Profile.DAILY):aggregate_blocks(BY_MAX()):aggregate_stages(BY_AVERAGE(), Profile.PER_MONTH):aggregate_scenarios(BY_AVERAGE());
    --     end
    --     -- tmp_reserva:save("tmp_reserva" .. tostring(stage), {tmp = true, csv = false});
    --     -- apagao_reserva_dia:select_stages(stage):reshape_stages(Profile.DAILY):save("tmp_reserva_intermediario" .. tostring(stage), {tmp = true, csv = false});
    --     -- tmp_reserva = tmp_reserva - tmp_severo; -- quando acontece apagao severo, também acontece apagão na reserva, mas não queremos dupla contagem
    --     -- chart9_2:add_column_stacking(tmp_severo:convert("%"):round(number_of_digits_round):rename_agents({"Corte de carga. Mês: " .. tostring(month)}), {color="purple"});
    --     -- chart9_2:add_column_stacking(tmp_reserva:convert("%"):round(number_of_digits_round):rename_agents({"Violação da reserva. Mês: " .. tostring(month)}), {color="orange"});
    -- end
    tmp_severo  = apagao_severo_dia:reshape_stages(Profile.DAILY):aggregate_blocks(BY_MAX()):aggregate_stages(BY_AVERAGE(), Profile.PER_MONTH):aggregate_scenarios(BY_AVERAGE());
    tmp_reserva = apagao_reserva_dia:reshape_stages(Profile.DAILY):aggregate_blocks(BY_MAX()):aggregate_stages(BY_AVERAGE(), Profile.PER_MONTH):aggregate_scenarios(BY_AVERAGE());
    tmp_reserva = tmp_reserva - tmp_severo; -- quando acontece apagao severo, também acontece apagão na reserva, mas não queremos dupla contagem
    chart9_2:add_column_stacking(tmp_severo:convert("%"):round(number_of_digits_round):rename_agents({"Corte de carga. Mês"}), {color="purple"});
    chart9_2:add_column_stacking(tmp_reserva:convert("%"):round(number_of_digits_round):rename_agents({"Violação da reserva"}), {color="orange"});
    dashboard9:push(chart9_2);

    local md = Markdown();
    md:add("## Severidade do corte de carga ao longo do dia");
    md:add("Para cada hora do ciclo diário, o RiskBoard informa o valor esperado dos 5% piores cortes de carga (pode incluir situações com zero corte) dentre os " .. tostring(numero_cenarios_potencia)  ..  " cenários de atenção vezes o número de dias do mês. O objetivo desta medida, que equivale a um “Conditioned Value at Risk” (CVaR), é dar uma visão sobre a hora do dia em que podem ocorrer interrupções. Observa-se que esta hora pode não corresponder à demanda máxima por causa do efeito da geração eólica e solar.");
    dashboard9:push(md);

    -- cvar
    local stages = mismatch_power:stages();
    for stage = 1,stages,1 do
        local month = mismatch_power:month(stage);
        local chart9_3 = Chart("Severidade do blecaute (CVAR) - Mês: " .. tostring(month));
        local tmp_severo = ifelse(mismatch_power:gt(0), mismatch_power/demand_hr, 0):convert("%"):select_stages(stage):reshape_stages(Profile.DAILY):aggregate_scenarios_stages(BY_CVAR_R(5)):round(number_of_digits_round);
        -- :aggregate_stages(BY_AVERAGE()):aggregate_scenarios(BY_AVERAGE());
        chart9_3:add_column(tmp_severo:rename_agents({"Corte de carga médio (CVAR)"}), {color="purple"});
        dashboard9:push(chart9_3);
    end


    if is_complete then
        local stages = mismatch_power_reserva:stages();
        for stage = 1,stages,1 do
            local month = mismatch_power_reserva:month(stage);
            local chart9_4 = Chart("Histograma - blecaute - reserva - condicional - Mês: " .. tostring(month));
            demanda_estagio = (demand_hr * criterio_severidade_de_apagao):select_stages(stage);
            mismatch_power_reserva_estagio = mismatch_power_reserva:select_stages(stage);
            mismatch_power_reserva_estagio_fake_agents = ifelse(mismatch_power_reserva_estagio:gt(0), mismatch_power_reserva_estagio / demanda_estagio, 0):convert("%"):blocks_to_agents():scenarios_to_agents();
            mismatch_power_reserva_estagio_fake_agents = mismatch_power_reserva_estagio_fake_agents:select_agents(mismatch_power_reserva_estagio_fake_agents:gt(0));
            chart9_4:add_histogram(mismatch_power_reserva_estagio_fake_agents:rename_agents("blecaute reserva - relativo à demanda"), {color="#d3d3d3"}); -- grey -- xtickPositions="[0, 20, 40, 60, 80, 100]"
            dashboard9:push(chart9_4);
        end
    end
end
if bool_potencia and numero_cenarios_potencia == 0 then
    local md = Markdown();
    md:add("### Não apresentamos resultados de análise de suprimento de potência porque não há cenários de atenção.");
    dashboard9:push(md);
end


local dashboard11 = Dashboard("Resumo");
if bool_potencia then
    local md = Markdown();
    md:add("# Resumo");
    md:add("## Resumo do risco de suprimento de Energia e Potência");
    md:add("O gráfico a seguir mostra resultados consolidados apresentados nas abas \"Energia\" e \"Potência\":");
        md:add("- \"Normal\" (Verde): Percentual (%) dos cenários simulados nos quais não foram detectados problemas no suprimento de Energia e de Potência.");
        md:add("- \"Violação da reserva\" (Laranja): Percentual (%) dos cenários  onde não houve corte preventivo de energia, contudo houve problemas de potência. Mais especificamente, em mais de 1% das horas a oferta total foi superior à demanda, porém inferior a reserva: situação operativa de alerta.");
        md:add("- \"Corte de carga\" (Roxo): Percentual (%) dos cenários  onde não houve corte preventivo de energia, contudo houve problemas de potência. Mais especificamente, em mais de 1% doas horas a oferta total inferior à demanda: corte de carga (blecaute rotativo).");
        md:add("- \"Racionamento\" (Vermelho): Percentual (%) dos cenários simulados nos quais foi necessário corte de consumo de energia, indicando a necessidade de um racionamento.");
        dashboard11:push(md);
        dashboard11:push("  ");
end
if bool_potencia then

    risco_racionamento = ifelse(study.stage:select_stages(1,last_stage):gt(last_stage-3), enearm_final_risk_level2_SE_or_SU_pie, 0);
    if numero_cenarios_potencia > 0 then
        risco_apagao_severo = (risco_apagao_severo * enearm_final_risk_level1_SE_or_SU_pie):convert("%");
        risco_apagao_reserva = (risco_apagao_reserva * enearm_final_risk_level1_SE_or_SU_pie):convert("%");
    else
        risco_apagao_severo = study.stage:select_stages(1,last_stage) * 0.0;
        risco_apagao_reserva =  study.stage:select_stages(1,last_stage) * 0.0;
    end
    sem_risco_apagao_ou_energia = 100 - (risco_racionamento + risco_apagao_severo + risco_apagao_reserva);

    local chart11_1 = Chart("Suprimento de energia e potência");
    chart11_1:add_column_stacking(risco_racionamento:rename_agents({"Racionamento"}), {color="red", yMax="100"});
    chart11_1:add_column_stacking(risco_apagao_severo:rename_agents({"Corte de carga"}), {color="purple"});
    chart11_1:add_column_stacking(risco_apagao_reserva:rename_agents({"Violação da reserva"}), {color="orange"});
    chart11_1:add_column_stacking(sem_risco_apagao_ou_energia:rename_agents({"Normal"}), {color="Green"});
    dashboard11:push(chart11_1);
end



-- demand_hr:convert("GW"):aggregate_blocks(BY_MAX()):save("cache_demand", {tmp = false, csv = true});
-- -- gergnd_hr:select_scenarios(1):convert("GW"):save("cache_gergnd_hr", {tmp = true, csv = false});
-- -- thermal_generation_block:select_scenarios(1):convert("GW"):save("cache_thermal_generation_block", {tmp = true, csv = false});
-- -- capint2_SE_block:select_scenarios(1):convert("GW"):to_hour(BY_REPEATING()):save("cache_capint2_SE_block", {tmp = true, csv = false});
-- hydro_max_power:convert("GW"):save("cache_hydro_max_power", {tmp = false, csv = true});
-- hydro_max_power_disponivel:convert("GW"):save("cache_hydro_max_power_disponivel", {tmp = false, csv = true});

-- ( pothid:convert("GW") - hydro_max_power:select_scenarios(1):convert("GW")):save("cache_dif_pothid", {tmp = true, csv = false});

-- SU-MLT	SE-MLT	NE-MLT	NO-MLT
Inflow_energia_mlt_total = Inflow_energia_mlt:select_stages(11-last_stage+1,11):aggregate_stages(BY_AVERAGE()):aggregate_agents(BY_SUM(), "ENA_TOTAL");
Inflow_energia_mlt_sul = Inflow_energia_mlt:select_stages(11-last_stage+1,11):aggregate_stages(BY_AVERAGE()):select_agents({"SU-MLT"}):aggregate_agents(BY_SUM(), "ENA_SUL");
Inflow_energia_mlt_sudeste = Inflow_energia_mlt:select_stages(11-last_stage+1,11):aggregate_stages(BY_AVERAGE()):select_agents({"SE-MLT"}):aggregate_agents(BY_SUM(), "ENA_TOTAL");
Inflow_energia_mlt_sul_e_sudeste = Inflow_energia_mlt:select_stages(11-last_stage+1,11):aggregate_stages(BY_AVERAGE()):select_agents({"SU-MLT", "SE-MLT"}):aggregate_agents(BY_SUM(), "ENA_TOTAL");
print(Inflow_energia_mlt_total);
print(Inflow_energia_mlt_sul);
print(Inflow_energia_mlt_sudeste);
print(Inflow_energia_mlt_sul_e_sudeste);
local dashboard12 = nil;
if true then
    dashboard12 = Dashboard("ENA - cenários");
    local md_tabela_enas = Markdown();
    local cenarios_ena = {};
    local numero_cenarios_ena = 0;
    cenarios_normal_list = cenarios_normal:to_int_list();
    for cenario, value in ipairs( cenarios_normal_list ) do
        if value == 1 then
            table.insert(cenarios_ena, cenario);
            numero_cenarios_ena = numero_cenarios_ena + 1;
        end
    end
    cenarios_atencao_list = cenarios_atencao:to_int_list();
    for cenario, value in ipairs( cenarios_atencao_list ) do
        if value == 1 then
            table.insert(cenarios_ena, cenario);
            numero_cenarios_ena = numero_cenarios_ena + 1;
        end
    end
    cenarios_racionamento_list = cenarios_racionamento:to_int_list();
    for cenario, value in ipairs( cenarios_racionamento_list ) do
        if value == 1 then
            table.insert(cenarios_ena, cenario);
            numero_cenarios_ena = numero_cenarios_ena + 1;
        end
    end
    scenarios = Inflow_energia:select_scenarios(cenarios_ena):scenarios();
    md_tabela_enas:add("# Tabela de ENAs");
    md_tabela_enas:add("Cenario | Normal (0/1) | Atencao (0/1) | Deficit (0/1) | ENA total (%) | ENA Sul (%) | ENA Sudeste (%) | ENA Sul + Sudeste (%)");
    md_tabela_enas:add("-:|-:|-:|-:|-:|-:|-:|-:");
    for scenario = 1,numero_cenarios_ena,1 do
        -- print(scenario);
        Inflow_energia_mlt = generic:load("enafluMLT"):select_stages(1,11):convert("GW");
        ena_total = Inflow_energia:aggregate_stages(BY_AVERAGE()):select_scenarios(cenarios_ena):select_scenarios({scenario}):aggregate_agents(BY_SUM(), "ENA_TOTAL");
        ena_sul = Inflow_energia:aggregate_stages(BY_AVERAGE()):select_scenarios(cenarios_ena):select_scenarios({scenario}):select_agents({"SUL"}):aggregate_agents(BY_SUM(), "ENA_SUL");
        ena_sudeste = Inflow_energia:aggregate_stages(BY_AVERAGE()):select_scenarios(cenarios_ena):select_scenarios({scenario}):select_agents({"SUDESTE"}):aggregate_agents(BY_SUM(), "ENA_SUDESTE");
        ena_sul_e_sudeste = Inflow_energia:aggregate_stages(BY_AVERAGE()):select_scenarios(cenarios_ena):select_scenarios({scenario}):select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "ENA_SUDESTE");
        md_tabela_enas:add(cenarios_ena[scenario]
                                    .. " | " .. string.format("%.1f", tostring(cenarios_normal:select_scenarios(cenarios_ena):select_scenarios({scenario}):to_list()[1]))
                                    .. " | " .. string.format("%.1f", tostring(cenarios_atencao:select_scenarios(cenarios_ena):select_scenarios({scenario}):to_list()[1]))
                                    .. " | " .. string.format("%.1f", tostring(cenarios_racionamento:select_scenarios(cenarios_ena):select_scenarios({scenario}):to_list()[1]))
                                    .. " | " .. string.format("%.1f", tostring((ena_total/Inflow_energia_mlt_total):convert("%"):to_list()[1]))
                                    .. " | " .. string.format("%.1f", tostring((ena_sul/Inflow_energia_mlt_sul):convert("%"):to_list()[1]))
                                    .. " | " .. string.format("%.1f", tostring((ena_sudeste/Inflow_energia_mlt_sudeste):convert("%"):to_list()[1]))
                                    .. " | " .. string.format("%.1f", tostring((ena_sul_e_sudeste/Inflow_energia_mlt_sul_e_sudeste):convert("%"):to_list()[1]))
                                );
    end
    dashboard12:push(md_tabela_enas);
end

earmzm_sul = earmzm:select_agents({"SUL"}):aggregate_agents(BY_SUM(), "EARM_SUL");
earmzm_sudeste = earmzm:select_agents({"SUDESTE"}):aggregate_agents(BY_SUM(), "EARM_TOTAL");
earmzm_sul_e_sudeste = earmzm:select_agents({"SUL", "SUDESTE"}):aggregate_agents(BY_SUM(), "EARM_TOTAL");
print(earmzm_sul);
print(earmzm_sudeste);
print(earmzm_sul_e_sudeste);
local dashboard13 = nil;
if true then
    dashboard13 = Dashboard("EARM - cenários");
    local md_tabela_earm = Markdown();
    local cenarios_earm = {};
    local numero_cenarios_earm = 0;
    cenarios_normal_list = cenarios_normal:to_int_list();
    for cenario, value in ipairs( cenarios_normal_list ) do
        if value == 1 then
            table.insert(cenarios_earm, cenario);
            numero_cenarios_earm = numero_cenarios_earm + 1;
        end
    end
    cenarios_atencao_list = cenarios_atencao:to_int_list();
    for cenario, value in ipairs( cenarios_atencao_list ) do
        if value == 1 then
            table.insert(cenarios_earm, cenario);
            numero_cenarios_earm = numero_cenarios_earm + 1;
        end
    end
    cenarios_racionamento_list = cenarios_racionamento:to_int_list();
    for cenario, value in ipairs( cenarios_racionamento_list ) do
        if value == 1 then
            table.insert(cenarios_earm, cenario);
            numero_cenarios_earm = numero_cenarios_earm + 1;
        end
    end
    md_tabela_earm:add("# Tabela de EARMs");
    md_tabela_earm:add("Cenario | Normal (0/1) | Atencao (0/1) | Deficit (0/1) | EARM Sul (%) | EARM Sudeste (%) | EARM Sul + Sudeste (%)");
    md_tabela_earm:add("-:|-:|-:|-:|-:|-:|-:");
    for scenario = 1,numero_cenarios_earm,1 do
        enearm_SU_final_scenario = enearm_SU_final:select_scenarios(cenarios_earm):select_scenarios({scenario});
        enearm_SE_final_scenario = enearm_SE_final:select_scenarios(cenarios_earm):select_scenarios({scenario});
        enearm_SE_E_SU_final_scenario = enearm_SU_final_scenario + enearm_SE_final_scenario;
        -- print(scenario);
        -- print(enearm_SU_final_scenario);
        -- print(enearm_SE_final_scenario);
        -- print(enearm_SE_E_SU_final_scenario);
        -- print(earmzm_sul);
        -- print(earmzm_sudeste);
        -- print(earmzm_sul_e_sudeste);
        md_tabela_earm:add(cenarios_earm[scenario]
                                    .. " | " .. string.format("%.1f", tostring(cenarios_normal:select_scenarios(cenarios_earm):select_scenarios({scenario}):to_list()[1]))
                                    .. " | " .. string.format("%.1f", tostring(cenarios_atencao:select_scenarios(cenarios_earm):select_scenarios({scenario}):to_list()[1]))
                                    .. " | " .. string.format("%.1f", tostring(cenarios_racionamento:select_scenarios(cenarios_earm):select_scenarios({scenario}):to_list()[1]))
                                    .. " | " .. string.format("%.1f", tostring((enearm_SU_final_scenario/earmzm_sul):convert("%"):to_list()[1]))
                                    .. " | " .. string.format("%.1f", tostring((enearm_SE_final_scenario/earmzm_sudeste):convert("%"):to_list()[1]))
                                    .. " | " .. string.format("%.1f", tostring((enearm_SE_E_SU_final_scenario/earmzm_sul_e_sudeste):convert("%"):to_list()[1]))
                                );
    end
    dashboard13:push(md_tabela_earm);
end

if bool_potencia then
    (dashboard7 + dashboard8 + dashboard10 + dashboard2 + dashboard9 + dashboard11 + dashboard12 + dashboard13):save("risk");
else
    (dashboard7 + dashboard8 + dashboard10 + dashboard2 + dashboard12 + dashboard13):save("risk");
end
-- (dashboard9):save("risk");