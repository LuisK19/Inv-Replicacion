-- =============================================
-- CONFIGURACIÓN DE REPLICACIÓN PEER-TO-PEER
-- SQL Server 2022 - AdventureWorks
-- =============================================

/*
OBJETIVO: Configurar replicación bidireccional entre dos bases de datos 
AdventureWorks en el mismo servidor para las tablas:
- Production.Product
- Production.ProductCategory  
- Production.ProductSubcategory
*/

-- =============================================
-- 1. CONFIGURACIÓN DEL DISTRIBUIDOR
-- =============================================

/*
El distribuidor es el componente central de la replicación que almacena
los datos de seguimiento y los comandos de replicación. Aquí lo configuramos
en la base de datos 'distribution' que se creará automáticamente.
*/

USE [master];
GO

-- Obtener el nombre del servidor actual
DECLARE @distributor SYSNAME;
SELECT @distributor = @@SERVERNAME;

-- Crear el distribuidor con contraseña de administración
EXEC sp_adddistributor 
    @distributor = @distributor, 
    @password = N'Admin1234*';
GO

-- Crear la base de datos de distribución con configuración específica
EXEC sp_adddistributiondb 
    @database = N'distribution', 
    @data_folder = N'/var/opt/mssql/Data',      -- Ruta para archivos de datos
    @log_folder = N'/var/opt/mssql/Data',       -- Ruta para archivos de log
    @log_file_size = 2,                         -- Tamaño inicial del log (MB)
    @min_distretention = 0,                     -- Retención mínima (horas)
    @max_distretention = 72,                    -- Retención máxima (horas)
    @history_retention = 48,                    -- Retención de historial (horas)
    @deletebatchsize_xact = 5000,               -- Tamaño de lote para eliminar transacciones
    @deletebatchsize_cmd = 2000,                -- Tamaño de lote para eliminar comandos
    @security_mode = 1;                         -- Autenticación Windows (1) / SQL Server (0)
GO

-- =============================================
-- 2. CONFIGURACIÓN DEL PUBLICADOR
-- =============================================

/*
El publicador es el servidor que contiene los datos originales que serán
replicados. Configuramos las propiedades extendidas para la carpeta de
instantáneas donde se almacenan los archivos de replicación.
*/

USE [distribution];
GO

-- Verificar y crear la tabla UIProperties si no existe
IF (NOT EXISTS (SELECT * FROM sysobjects WHERE name = 'UIProperties' AND type = 'U')) 
    CREATE TABLE UIProperties(id INT);

-- Configurar la carpeta de instantáneas (snapshots)
IF (EXISTS (SELECT * FROM ::fn_listextendedproperty('SnapshotFolder', 'user', 'dbo', 'table', 'UIProperties', NULL, NULL))) 
    EXEC sp_updateextendedproperty N'SnapshotFolder', N'/var/opt/mssql/ReplData', 'user', dbo, 'table', 'UIProperties';
ELSE 
    EXEC sp_addextendedproperty N'SnapshotFolder', N'/var/opt/mssql/ReplData', 'user', dbo, 'table', 'UIProperties';
GO

-- Obtener el nombre del publicador (mismo servidor)
DECLARE @publisher SYSNAME;
SELECT @publisher = @@SERVERNAME;

-- Agregar el publicador al distribuidor
EXEC sp_adddistpublisher 
    @publisher = @publisher, 
    @distribution_db = N'distribution', 
    @security_mode = 0,                         -- Autenticación SQL Server
    @login = N'sa',                             -- Usuario administrador
    @password = N'Admin1234*',                  -- Contraseña
    @working_directory = N'/var/opt/mssql/ReplData', -- Carpeta de trabajo
    @trusted = N'false',                        -- No usar conexiones trusted
    @thirdparty_flag = 0,                       -- No es tercer party
    @publisher_type = N'MSSQLSERVER';           -- Tipo de publicador
GO

-- =============================================
-- 3. CREACIÓN DE LA PUBLICACIÓN (VIA WIZARD)
-- =============================================

/*
NOTA: Este paso se realiza mediante el Asistente de Replicación en SSMS:

1. Conectar al servidor en el Object Explorer
2. Expandir "Replication" > "Local Publications"
3. Clic derecho > "New Publication"
4. Seleccionar "AdventureWorks2022" como database
5. Elegir "Peer-to-Peer Publication" como tipo
6. Seleccionar las tablas: 
   - Production.Product
   - Production.ProductCategory  
   - Production.ProductSubcategory
7. Configurar seguridad con login 'sa' y password 'Admin1234*'
8. Nombrar la publicación como 'Repl-AW'
9. Finalizar el wizard

La publicación quedará creada y lista para agregar suscriptores.
*/

-- =============================================
-- 4. AGREGAR PRIMERA SUSCRIPCIÓN (BIDIRECCIONAL)
-- =============================================

/*
Configuramos la primera dirección de replicación: desde AdventureWorks2022 
hacia AdventureWorks2022-Backup usando suscripción PUSH.
*/

DECLARE @server SYSNAME;
SELECT @server = @@SERVERNAME;

USE [AdventureWorks2022];
GO

-- Crear la suscripción hacia la base de datos backup
EXEC sp_addsubscription 
    @publication = N'Repl-AW', 
    @subscriber = @server, 
    @destination_db = N'AdventureWorks2022-Backup', 
    @subscription_type = N'Push',               -- Agente en el distribuidor
    @sync_type = N'replication support only',   -- Ya existen los datos
    @article = N'all',                          -- Todos los artículos
    @update_mode = N'read only',                -- Modo de actualización
    @subscriber_type = 0;                       -- Tipo de suscriptor

-- Agregar el agente de suscripción push
EXEC sp_addpushsubscription_agent 
    @publication = N'Repl-AW', 
    @subscriber = @server, 
    @subscriber_db = N'AdventureWorks2022-Backup', 
    @job_login = NULL,                          -- Usar credenciales del servicio
    @job_password = NULL, 
    @subscriber_security_mode = 1,              -- Autenticación Windows
    @frequency_type = 64,                       -- Ejecución continua
    @frequency_interval = 0,
    @frequency_relative_interval = 0,
    @frequency_recurrence_factor = 0, 
    @frequency_subday = 0, 
    @frequency_subday_interval = 0,
    @active_start_time_of_day = 0,
    @active_end_time_of_day = 235959, 
    @active_start_date = 20241023,
    @active_end_date = 99991231,
    @enabled_for_syncmgr = N'False',
    @dts_package_location = N'Distributor';
GO

-- =============================================
-- 5. CONFIGURACIÓN PEER-TO-PEER (VIA WIZARD)
-- =============================================

/*
NOTA: Este paso se realiza mediante el Diagrama Peer-to-Peer en SSMS:

1. Expandir "Replication" > "Local Publications" 
2. Clic derecho en "Repl-AW" > "Configure Peer-to-Peer Topology"
3. Agregar nuevo nodo con la base de datos "AdventureWorks2022-Backup"
4. Configurar la seguridad y conexiones
5. Inicializar la topología
6. Verificar que ambos nodos estén conectados

Esto habilita la replicación bidireccional completa.
*/

-- =============================================
-- 6. AGREGAR SEGUNDA SUSCRIPCIÓN (BIDIRECCIONAL)
-- =============================================

/*
Configuramos la dirección inversa: desde AdventureWorks2022-Backup 
hacia AdventureWorks2022 para completar la bidireccionalidad.
*/

DECLARE @server SYSNAME;
SELECT @server = @@SERVERNAME;

USE [AdventureWorks2022-Backup];
GO

-- Crear la suscripción inversa
EXEC sp_addsubscription 
    @publication = N'Repl-AW', 
    @subscriber = @server, 
    @destination_db = N'AdventureWorks2022', 
    @subscription_type = N'Push',
    @sync_type = N'replication support only',
    @article = N'all', 
    @update_mode = N'read only',
    @subscriber_type = 0;

-- Agregar el agente de suscripción push inverso
EXEC sp_addpushsubscription_agent 
    @publication = N'Repl-AW', 
    @subscriber = @server, 
    @subscriber_db = N'AdventureWorks2022', 
    @job_login = NULL, 
    @job_password = NULL, 
    @subscriber_security_mode = 1, 
    @frequency_type = 64, 
    @frequency_interval = 0,
    @frequency_relative_interval = 0,
    @frequency_recurrence_factor = 0, 
    @frequency_subday = 0, 
    @frequency_subday_interval = 0,
    @active_start_time_of_day = 0,
    @active_end_time_of_day = 235959, 
    @active_start_date = 20241023,
    @active_end_date = 99991231,
    @enabled_for_syncmgr = N'False',
    @dts_package_location = N'Distributor';
GO

-- =============================================
-- 7. PRUEBAS DE FUNCIONALIDAD DE REPLICACIÓN
-- =============================================

/*
Realizamos pruebas para verificar que la replicación funciona correctamente
en ambas direcciones: inserción, actualización y eliminación.
*/

-- =============================================
-- 7.1 PRUEBA DE INSERCIÓN
-- =============================================

/*
Objetivo: Verificar que los inserts se replican correctamente
*/

-- Insertar en la base de datos principal
INSERT INTO Production.Product (Name, ProductNumber, SafetyStockLevel, ReorderPoint, StandardCost, ListPrice, DaysToManufacture, SellStartDate)
VALUES ('Test Product', 'TP-001', 100, 50, 10.0, 20.0, 1, GETDATE());

INSERT INTO Production.Product (Name, ProductNumber, SafetyStockLevel, ReorderPoint, StandardCost, ListPrice, DaysToManufacture, SellStartDate)
VALUES ('Test Product2', 'TP-002', 100, 50, 10.0, 20.0, 1, GETDATE());

-- Verificar que aparecieron en la base de datos backup (debería replicarse automáticamente)
-- Ejecutar en AdventureWorks2022-Backup:
SELECT Name, ProductID, ProductNumber 
FROM Production.Product 
WHERE ProductNumber IN ('TP-001', 'TP-002');

-- =============================================
-- 7.2 PRUEBA DE ACTUALIZACIÓN  
-- =============================================

/*
Objetivo: Verificar que los updates se replican correctamente
*/

-- Actualizar en la base de datos backup
UPDATE Production.Product SET Name = 'Updated Product' WHERE ProductNumber = 'TP-001';
UPDATE Production.Product SET Name = 'Updated Product2' WHERE ProductNumber = 'TP-002';

-- Verificar que se actualizó en la base de datos principal (debería replicarse)
-- Ejecutar en AdventureWorks2022:
SELECT Name, ProductID, ProductNumber 
FROM Production.Product 
WHERE ProductNumber IN ('TP-001', 'TP-002');

-- =============================================
-- 7.3 PRUEBA DE ELIMINACIÓN
-- =============================================

/*
Objetivo: Verificar que los deletes se replican correctamente
*/

-- Eliminar en la base de datos principal
DELETE FROM Production.Product WHERE ProductNumber = 'TP-001';
DELETE FROM Production.Product WHERE ProductNumber = 'TP-002';

-- Verificar que se eliminaron en la base de datos backup (debería replicarse)
-- Ejecutar en AdventureWorks2022-Backup:
SELECT COUNT(*) as RemainingRecords
FROM Production.Product 
WHERE ProductNumber IN ('TP-001', 'TP-002');

-- =============================================
-- 8. CONSULTAS DE VERIFICACIÓN FINAL
-- =============================================

-- Verificar productos existentes en orden descendente por ID
SELECT Name, ProductID, ProductNumber
FROM Production.Product
ORDER BY ProductID DESC;

-- Consulta específica para verificar un producto conocido
SELECT Name, ProductID, ProductNumber
FROM Production.Product
WHERE ProductID = 1;

-- Actualización de prueba final
UPDATE Production.Product
SET Name = 'Adjustable Race 3'
WHERE ProductID = 1;

-- =============================================
-- FIN DEL SCRIPT DE CONFIGURACIÓN
-- =============================================