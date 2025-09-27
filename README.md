# Investigación: Microsoft SQL Server – Replicaciones

## 1. Introducción

El objetivo de esta investigación es configurar la replicación de datos entre dos bases de datos de AdventureWorks en el mismo servidor Microsoft SQL Server, específicamente para las tablas `Production.Product`, `Production.ProductCategory` y `Production.ProductSubcategory`. La replicación permitirá que las operaciones de inserción, modificación y eliminación realizadas en una base de datos se reflejen automáticamente en la otra. Esto servirá como base para el desarrollo de un Sistema de Bases de Datos Distribuidas en el segundo proyecto.

## 2. Descripción del entorno

Se utilizó Docker para crear un contenedor con Microsoft SQL Server 2022, donde se restauraron dos bases de datos: 
- `AdventureWorks2022` (base de datos principal).
- `AdventureWorks2022-Backup` (base de datos secundaria).

Ambas bases de datos se encuentran en el mismo servidor SQL Server dentro del contenedor. La replicación se configuró para ser bidireccional utilizando replicación transaccional peer-to-peer.

## 3. Configuración de Docker y SQL Server

### 3.1. Descargar la imagen de SQL Server
Se descargó la imagen oficial de SQL Server 2022 para Docker:
```bash
docker pull mcr.microsoft.com/mssql/server:2022-latest
```

### 3.2. Ejecutar el contenedor
Se inició un contenedor con las siguientes configuraciones:
```bash
docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=Admin1234*" -p 1539:1433 --name Repl-Docker -d mcr.microsoft.com/mssql/server:2022-latest
```

### 3.3. Habilitar el Agente SQL Server
El Agente SQL Server es necesario para la replicación. Se habilitó con:
```bash
docker exec -it Repl-Docker /opt/mssql/bin/mssql-conf set sqlagent.enabled true
docker stop Repl-Docker
docker start Repl-Docker
```

### 3.4. Restaurar la base de datos AdventureWorks
Se copió el archivo `AdventureWorks2022.bak` al contenedor y se restauró la base de datos. Luego, se creó una copia denominada `AdventureWorks2022-Backup`:
```bash
docker cp AdventureWorks2022.bak Repl-Docker:/var/opt/mssql/data
```
Dentro del contenedor, se usó SQL Server Management Studio (SSMS) o comandos T-SQL para restaurar la base de datos y crear la copia.

## 4. Configuración de la replicación

### 4.1. Configurar el distribuidor
El distribuidor se configuró ejecutando el siguiente script en la base de datos `master`:
```sql
USE [master];
DECLARE @distributor SYSNAME;
SELECT @distributor = @@SERVERNAME;
EXEC sp_adddistributor @distributor = @distributor, @password = N'Admin1234*';
EXEC sp_adddistributiondb 
    @database = N'distribution', 
    @data_folder = N'/var/opt/mssql/Data', 
    @log_folder = N'/var/opt/mssql/Data', 
    @security_mode = 1;
```

### 4.2. Configurar el publicador
Se configuró el publicador en la base de datos `distribution` y se estableció la carpeta de instantáneas:
```sql
USE [distribution];
EXEC sp_addextendedproperty N'SnapshotFolder', N'/var/opt/mssql/ReplData', 'user', dbo, 'table', 'UIProperties';
DECLARE @publisher SYSNAME;
SELECT @publisher = @@SERVERNAME;
EXEC sp_adddistpublisher 
    @publisher = @publisher, 
    @distribution_db = N'distribution', 
    @security_mode = 0, 
    @login = N'sa', 
    @password = N'Admin1234*', 
    @working_directory = N'/var/opt/mssql/ReplData';
```

### 4.3. Crear la publicación
Se utilizó el Asistente para replicación en SSMS para crear una publicación transaccional peer-to-peer:
- Se conectó al servidor en el contenedor.
- En el Explorador de objetos, se navegó a **Replicación** > **Publicaciones locales** > **Nueva publicación**.
- Se seleccionó la base de datos `AdventureWorks2022`.
- Se eligió **Replicación transaccional peer-to-peer**.
- Se seleccionaron las tablas `Production.Product`, `Production.ProductCategory` y `Production.ProductSubcategory`.
- Se configuró la seguridad usando el login `sa` y la contraseña.
- Se generó la publicación con el nombre `Repl-AW`.

### 4.4. Agregar suscripciones
Se agregaron suscripciones push bidireccionales entre las dos bases de datos. Primero, desde `AdventureWorks2022` a `AdventureWorks2022-Backup`:
```sql
USE [AdventureWorks2022];
EXEC sp_addsubscription 
    @publication = N'Repl-AW', 
    @subscriber = @@SERVERNAME, 
    @destination_db = N'AdventureWorks2022-Backup', 
    @subscription_type = N'Push';
EXEC sp_addpushsubscription_agent 
    @publication = N'Repl-AW', 
    @subscriber = @@SERVERNAME, 
    @subscriber_db = N'AdventureWorks2022-Backup', 
    @subscriber_security_mode = 1;
```

Luego, desde `AdventureWorks2022-Backup` a `AdventureWorks2022`:
```sql
USE [AdventureWorks2022-Backup];
EXEC sp_addsubscription 
    @publication = N'Repl-AW', 
    @subscriber = @@SERVERNAME, 
    @destination_db = N'AdventureWorks2022', 
    @subscription_type = N'Push';
EXEC sp_addpushsubscription_agent 
    @publication = N'Repl-AW', 
    @subscriber = @@SERVERNAME, 
    @subscriber_db = N'AdventureWorks2022', 
    @subscriber_security_mode = 1;
```

### 4.5. Configurar la replicación peer-to-peer
En SSMS, se usó el **Diagrama de replicación peer-to-peer** para agregar el segundo nodo (`AdventureWorks2022-Backup`) a la topología, asegurando que los cambios se repliquen en ambas direcciones.

## 5. Pruebas de replicación

Para verificar la funcionalidad, se realizaron las siguientes pruebas:

### 5.1. Inserción
- Se insertó un nuevo registro en `Production.Product` en `AdventureWorks2022`:
  ```sql
  INSERT INTO Production.Product (Name, ProductNumber, SafetyStockLevel, ReorderPoint, StandardCost, ListPrice, DaysToManufacture, SellStartDate)
  VALUES ('Test Product', 'TP-001', 100, 50, 10.0, 20.0, 1, GETDATE());
  ```
- Se verificó que el registro apareciera en `Production.Product` de `AdventureWorks2022-Backup`.

### 5.2. Actualización
- Se actualizó el nombre del producto en `AdventureWorks2022-Backup`:
  ```sql
  UPDATE Production.Product SET Name = 'Updated Product' WHERE ProductNumber = 'TP-001';
  ```
- Se confirmó el cambio en `AdventureWorks2022`.

### 5.3. Eliminación
- Se eliminó el registro en `AdventureWorks2022`:
  ```sql
  DELETE FROM Production.Product WHERE ProductNumber = 'TP-001';
  ```
- Se verificó que el registro se eliminara de `AdventureWorks2022-Backup`.

## 6. Conclusiones

La replicación peer-to-peer se configuró exitosamente, permitiendo que los cambios en las tablas seleccionadas se sincronicen entre ambas bases de datos. Esta configuración es fundamental para sistemas distribuidos donde la consistencia de datos es crítica.

### 6.1. Desafíos Superados
El proceso de implementación presentó varios desafíos técnicos que fueron resueltos mediante la adaptación de herramientas y estrategias:

**Problemas con Máquinas Virtuales:**
- Inicialmente se intentó la configuración usando Oracle VM VirtualBox con Ubuntu 24.04
- Se encontraron problemas de compatibilidad con SQL Server en esta versión específica
- Dificultades con la configuración de red y permisos entre el host y la máquina virtual
- Dificultades para asignar las publicaciones y suscripciones debido a problemas de puertos y que no se detectaban correctamente los servicios
- Limitaciones de rendimiento y complejidad en la gestión de snapshots

**Solución con Docker:**
- Migración exitosa a contenedores Docker que proporcionaron un entorno más estable
- Mayor compatibilidad con la imagen oficial de Microsoft SQL Server
- Simplificación de la gestión de red y almacenamiento
- Entorno reproducible y fácil de versionar

El uso de Docker no solo resolvió los problemas iniciales, sino que también proporcionó un entorno más eficiente y escalable para futuras implementaciones de bases de datos distribuidas.

## 7. Referencias

- Documentación de Microsoft SQL Server: [Replicación transaccional peer-to-peer](https://docs.microsoft.com/es-es/sql/relational-databases/replication/transactional/peer-to-peer-transactional-replication)
- Documentación de Docker: [Imágenes de SQL Server](https://hub.docker.com/_/microsoft-mssql-server)
- Microsoft Learn: [Configuración de SQL Server en Linux](https://learn.microsoft.com/es-es/sql/linux/sql-server-linux-setup)

---

**Video demostrativo:** [https://youtu.be/h2GS5vhHoh8](https://youtu.be/h2GS5vhHoh8).

**Código fuente:** [https://github.com/LuisK19/Inv-Replicacion](https://github.com/LuisK19/Inv-Replicacion)
