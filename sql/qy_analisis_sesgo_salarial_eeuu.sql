/*
=====================================================================================================
PROYECTO      : Análisis de Sesgo Salarial y Poder Adquisitivo en EE. UU. (Arquitectura Medallion)
SCRIPT        : qy_analisis_sesgo_salarial_eeuu.sql
CAPA          : Gold & Dimensiones (workspace.sch_oews_medallion)
FUENTE        : OEWS (Occupational Employment and Wage Statistics) — Año 2025
AUTOR         : JAGG
FECHA         : 11-NOV-2026
=====================================================================================================

1. OBJETIVO DEL ANÁLISIS:
   Brindar métricas salariales limpias y comparables para que un profesional especializado 
   (ej. cirujano o ingeniero de software) identifique el estado de EE. UU. con la mejor 
   relación costo/beneficio y calidad de vida.

2. PREGUNTAS DE NEGOCIO QUE RESUELVE:
   - ¿Qué es un "Estado Típico"? 
     Es el estado ubicado justo en la mediana económica del país (evitando extremos como 
     Nueva York/California o Misisipi).
   - ¿Qué es una "Profesión Típica"? 
     Es la ocupación ubicada en el centro del mercado laboral (50 % gana menos y 50 % gana más).
   - ¿Dónde rinde más el dinero en tecnología? 
     En estados donde el salario tech supera ampliamente el costo de vida local (medido a través 
     del salario medio estatal), priorizando el equilibrio financiero sobre el sueldo nominal más alto.

3. REGLAS DE CALIDAD DE DATOS (EXCLUSIÓN DE OUTLIERS):
   - Distrito de Columbia (DC): Se excluye por ser 100 % urbano y sede federal (sin zonas rurales 
     que equilibren su salario medio de $86,071.35, lo que infla artificialmente los promedios).
   - Puerto Rico (PR): Se excluye por ser un territorio no incorporado con una estructura salarial 
     atípica ($43,882.65, casi $10,000 por debajo del estado continental más bajo).

4. TABLAS GENERADAS EN ESTE SCRIPT:
   - tb_gld_state_salary_ranking  : Ranking salarial de los 50 estados y cálculo de mediana nacional.
   - tb_gld_occupation_ranking    : Ranking de 815 ocupaciones y brecha frente a la profesión típica.
   - tb_gld_tech_purchasing_power : Índice de poder adquisitivo tech (promedio ponderado por empleo).
   - tb_dim_estados               : Catálogo maestro de estados y territorios de EE. UU.

5. NOTA DE VIGENCIA:
   Las conclusiones documentadas al pie de cada sección corresponden exclusivamente al corte del año 
   2025; si se actualiza la fuente a un nuevo año, las conclusiones textuales deben ser revisadas 
   u omitidas.
=====================================================================================================
*/


-- ==================================================================================================
-- 1. ESTADO TÍPICO EN EE. UU.
-- ==================================================================================================
CREATE OR REPLACE TABLE workspace.sch_oews_medallion.tb_gld_state_salary_ranking AS
WITH cte_estados_metricas AS 
(
    SELECT 
        estado AS codigo_estado,
        salario_anual_medio_estado,
        salario_maximo_registrado,      
        ROW_NUMBER() OVER (ORDER BY salario_anual_medio_estado ASC) AS posicion_salarial 
    FROM workspace.sch_oews_medallion.tb_gld_state_summary
    WHERE estado NOT IN ('DC', 'PR')
),
cte_metricas_salariales_nacionales AS 
(
    SELECT   
        COUNT(*) AS total_registros,
        ROUND(AVG(salario_anual_medio_estado), 2) AS salario_promedio_nacional,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY salario_anual_medio_estado), 2) AS mediana_salario_tipico
    FROM cte_estados_metricas
)
SELECT 
    e.posicion_salarial,
    e.codigo_estado,
    e.salario_anual_medio_estado,
    e.salario_maximo_registrado,
    n.salario_promedio_nacional,
    n.mediana_salario_tipico,
    ROUND(n.salario_promedio_nacional / n.mediana_salario_tipico, 2) AS ratio_promedio_vs_mediana_salario,
    -- Qué tanto supera o queda por debajo cada estado frente al estado típico
    ROUND(e.salario_anual_medio_estado / n.mediana_salario_tipico, 2) AS indice_vs_estado_tipico,
    -- Etiqueta dinámica para clasificar la posición frente a la mediana nacional
    CASE 
        WHEN e.posicion_salarial IN (FLOOR((n.total_registros + 1) / 2.0), CEILING((n.total_registros + 1) / 2.0)) 
            THEN 'Estado Típico (Mediana)'
        WHEN e.posicion_salarial < FLOOR((n.total_registros + 1) / 2.0)
            THEN 'Por debajo de la Mediana'
        ELSE 'Por encima de la Mediana'
    END AS clasificacion_mediana
FROM cte_estados_metricas AS e
CROSS JOIN cte_metricas_salariales_nacionales AS n
ORDER BY e.posicion_salarial ASC;

/*
CONCLUSIÓN (SALARIOS - CORTE 2025):
Que la mediana de los 50 estados ($68,575.01) sea menor al promedio ($70,442.27) indica un sesgo 
positivo (asimetría a la derecha), provocado por un grupo reducido de estados con salarios muy altos 
que arrastran el promedio hacia arriba. En la práctica, la mayoría de los estados paga menos de lo 
que sugiere el promedio nacional. El ratio de 1.03 indica que el promedio salarial está inflado en 
apenas un 3 %, lo que confirma diferencias moderadas entre estados.
*/


-- ==================================================================================================
-- 2. PROFESIÓN TÍPICA EN EE. UU.
-- ==================================================================================================
CREATE OR REPLACE TABLE workspace.sch_oews_medallion.tb_gld_occupation_ranking AS
WITH cte_profesiones_metricas AS 
(
    SELECT 
        OCC_CODE AS codigo_ocupacion,
        OCC_TITLE AS titulo_ocupacion,            
        ROUND(AVG(a_mean_num), 2) AS salario_promedio_profesion_estado,
        ROW_NUMBER() OVER (ORDER BY ROUND(AVG(a_mean_num), 2) ASC) AS posicion_profesion                     
    FROM workspace.sch_oews_medallion.tb_slv_oews_clean
    WHERE PRIM_STATE NOT IN ('DC', 'PR')
        AND a_mean_num IS NOT NULL
    GROUP BY OCC_CODE, OCC_TITLE
),
cte_metricas_profesionales_nacionales AS 
(
    SELECT   
        COUNT(*) AS total_registros_profesion,
        ROUND(AVG(salario_promedio_profesion_estado), 2) AS salario_promedio_profesion_nacional,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY salario_promedio_profesion_estado), 2) AS mediana_salario_profesion_tipica
    FROM cte_profesiones_metricas
)
SELECT 
    p.posicion_profesion,
    p.codigo_ocupacion,
    p.titulo_ocupacion,
    p.salario_promedio_profesion_estado,
    g.salario_promedio_profesion_nacional,
    g.mediana_salario_profesion_tipica,
    ROUND((g.salario_promedio_profesion_nacional / g.mediana_salario_profesion_tipica), 2) AS ratio_promedio_vs_mediana_salario_profesion,
    -- Qué tanto supera o queda por debajo cada profesión frente a la profesión típica
    ROUND(p.salario_promedio_profesion_estado / g.mediana_salario_profesion_tipica, 2) AS indice_vs_profesion_tipica,
    -- Etiqueta dinámica para clasificar la posición frente a la mediana ocupacional
    CASE 
        WHEN p.posicion_profesion IN (FLOOR((g.total_registros_profesion + 1) / 2.0), CEILING((g.total_registros_profesion + 1) / 2.0))  
            THEN 'Profesión Típica (Mediana)'
        WHEN p.posicion_profesion < FLOOR((g.total_registros_profesion + 1) / 2.0)            
            THEN 'Por debajo de la Mediana'
        ELSE 'Por encima de la Mediana'
    END AS clasificacion_mediana
FROM cte_profesiones_metricas AS p
CROSS JOIN cte_metricas_profesionales_nacionales AS g
ORDER BY p.posicion_profesion ASC;

/*
CONCLUSIÓN (PROFESIONES - CORTE 2025):
Que la mediana de las 815 profesiones ($63,566.00) sea considerablemente menor al promedio ($76,321.55) 
confirma un fuerte sesgo positivo, causado por un grupo reducido de ocupaciones de élite (medicina 
especializada, alta gerencia) cuyos salarios elevados jalan la media hacia arriba. Esto demuestra que 
más de la mitad de las ocupaciones perciben ingresos sustancialmente menores al promedio nacional 
(una diferencia cercana al 20 %, con un ratio de 1.20), haciendo de la mediana un indicador mucho más 
realista del ingreso laboral típico.
*/


-- ==================================================================================================
-- 3. ÍNDICE DE PODER ADQUISITIVO (TECNOLOGÍA VS. ESTADO)
-- ==================================================================================================
CREATE OR REPLACE TABLE workspace.sch_oews_medallion.tb_gld_tech_purchasing_power AS
WITH cte_salarios_tech_estados AS 
(
    SELECT 
        estado,
        -- Promedio ponderado por la cantidad de empleados en cada rol tech
        ROUND(SUM(salario_anual_promedio * total_empleados) / NULLIF(SUM(total_empleados), 0), 2) AS salario_promedio_tech_estado,
        SUM(total_empleados) AS empleo_tech_estado
    FROM workspace.sch_oews_medallion.tb_gld_tech_salaries
    WHERE estado NOT IN ('DC', 'PR')
      AND total_empleados IS NOT NULL
    GROUP BY estado
)
SELECT 
    ROW_NUMBER() OVER (ORDER BY ROUND(t.salario_promedio_tech_estado / s.salario_anual_medio_estado, 2) DESC) AS ranking_poder_adquisitivo,
    t.estado AS codigo_estado,
    t.salario_promedio_tech_estado,
    ROUND(s.salario_anual_medio_estado, 2) AS salario_medio_estado,
    s.mediana_salario_tipico,        
    -- Índice de Poder Adquisitivo: cuántas veces el sueldo tech supera el promedio local
    ROUND(t.salario_promedio_tech_estado / s.salario_anual_medio_estado, 2) AS indice_poder_adquisitivo,        
    -- Clasificación dinámica usando +/- 5 % alrededor de la mediana nacional (tb_gld_state_salary_ranking)
    CASE 
        WHEN s.salario_anual_medio_estado < (s.mediana_salario_tipico * 0.95) 
            THEN 'Costo de vida Bajo'
        WHEN s.salario_anual_medio_estado BETWEEN (s.mediana_salario_tipico * 0.95) AND (s.mediana_salario_tipico * 1.05) 
            THEN 'Estado Típico (Moderado)'
        ELSE 'Costo de vida Alto'
    END AS perfil_economico_estado,
    t.empleo_tech_estado
FROM cte_salarios_tech_estados AS t
INNER JOIN workspace.sch_oews_medallion.tb_gld_state_salary_ranking AS s
ON t.estado = s.codigo_estado
ORDER BY ranking_poder_adquisitivo ASC;
/*
CONCLUSIÓN (PODER ADQUISITIVO TECH - CORTE 2025):
Para un profesional de tecnología, los estados donde más rinde el dinero no son los grandes centros
financieros (como California o Nueva York), sino aquellos con costo de vida bajo o moderado (como
Oregón, Carolina del Norte, Texas o Georgia). En estos estados, los salarios tecnológicos superan
entre 1.5 y 1.7 veces el ingreso promedio local, maximizando la capacidad de ahorro y calidad de vida.
*/
-- ==================================================================================================
-- 4. CATÁLOGO DE ESTADOS Y TERRITORIOS DE EE. UU. (TABLA DIMENSIONAL)
-- ==================================================================================================
CREATE OR REPLACE TABLE workspace.sch_oews_medallion.tb_dim_estados AS
SELECT * FROM VALUES
('AL', 'Alabama', 'Sur'),
('AK', 'Alaska', 'Oeste'),
('AZ', 'Arizona', 'Oeste'),
('AR', 'Arkansas', 'Sur'),
('CA', 'California', 'Oeste'),
('CO', 'Colorado', 'Oeste'),
('CT', 'Connecticut', 'Noreste'),
('DE', 'Delaware', 'Sur'),
('FL', 'Florida', 'Sur'),
('GA', 'Georgia', 'Sur'),
('HI', 'Hawai', 'Oeste'),
('ID', 'Idaho', 'Oeste'),
('IL', 'Illinois', 'Medio Oeste'),
('IN', 'Indiana', 'Medio Oeste'),
('IA', 'Iowa', 'Medio Oeste'),
('KS', 'Kansas', 'Medio Oeste'),
('KY', 'Kentucky', 'Sur'),
('LA', 'Luisiana', 'Sur'),
('ME', 'Maine', 'Noreste'),
('MD', 'Maryland', 'Sur'),
('MA', 'Massachusetts', 'Noreste'),
('MI', 'Míchigan', 'Medio Oeste'),
('MN', 'Minnesota', 'Medio Oeste'),
('MS', 'Misisipi', 'Sur'),
('MO', 'Misuri', 'Medio Oeste'),
('MT', 'Montana', 'Oeste'),
('NE', 'Nebraska', 'Medio Oeste'),
('NV', 'Nevada', 'Oeste'),
('NH', 'Nuevo Hampshire', 'Noreste'),
('NJ', 'Nueva Jersey', 'Noreste'),
('NM', 'Nuevo México', 'Oeste'),
('NY', 'Nueva York', 'Noreste'),
('NC', 'Carolina del Norte', 'Sur'),
('ND', 'Dakota del Norte', 'Medio Oeste'),
('OH', 'Ohio', 'Medio Oeste'),
('OK', 'Oklahoma', 'Sur'),
('OR', 'Oregón', 'Oeste'),
('PA', 'Pensilvania', 'Noreste'),
('RI', 'Rhode Island', 'Noreste'),
('SC', 'Carolina del Sur', 'Sur'),
('SD', 'Dakota del Sur', 'Medio Oeste'),
('TN', 'Tennessee', 'Sur'),
('TX', 'Texas', 'Sur'),
('UT', 'Utah', 'Oeste'),
('VT', 'Vermont', 'Noreste'),
('VA', 'Virginia', 'Sur'),
('WA', 'Washington', 'Oeste'),
('WV', 'Virginia Occidental', 'Sur'),
('WI', 'Wisconsin', 'Medio Oeste'),
('WY', 'Wyoming', 'Oeste'),
('DC', 'Distrito de Columbia', 'Territorio / Federal'),
('PR', 'Puerto Rico', 'Territorio')
AS t(codigo_estado, nombre_estado, region);

