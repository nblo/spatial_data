-- distance query substation - waterway
select 
	osm_id as id_substation, 
	geometry as geom_substation, 
	geom_waterway, 
	id_waterway, 
	st_distance(s.geometry, subq.geom_waterway) as distance_m
from deep_dive.substation s 
cross join lateral (
	select 
		osm_id as id_waterway, 
		geometry as geom_waterway
	from deep_dive.waterway w 
	where st_dwithin(s.geometry, w.geometry, 400)
) subq
where st_area(s.geometry) > 500
order by distance_m asc

-- neighbor query substation - waterway
select 
	osm_id as id_substation, 
	geometry as geom_substation, 
	geom_waterway, 
	id_waterway, 
	st_distance(s.geometry, subq.geom_waterway) as distance_m
from deep_dive.substation s 
cross join lateral (
	select 
		osm_id as id_waterway, 
		geometry as geom_waterway
	from deep_dive.waterway w 
	--where st_dwithin(s.geometry, w.geometry, 400)
	order by  w.geometry <-> s.geometry
	limit 1
) subq
where st_area(s.geometry) > 500
order by distance_m asc

-- fire stations and buildings 
select 
	osm_id as id_building, 
	geometry as geom_building,
	geom_firestation, 
	id_firestation,
	st_distance(b.geometry, subq.geom_firestation) as distance_m
from deep_dive.building b
cross join lateral (
	select 
		osm_id as id_firestation, 
		geometry as geom_firestation
	from deep_dive.fire_stations fss 
	order by  b.geometry <-> fss.geometry
	limit 1
) subq
order by id_firestation


-- create table mapping all served houses to firestation
with distance_mapping as (
select 
	osm_id as id_building, 
	geometry as geom_building,
	geom_firestation, 
	id_firestation,
	st_distance(b.geometry, subq.geom_firestation) as distance_m
from deep_dive.building b
cross join lateral (
	select 
		osm_id as id_firestation, 
		geometry as geom_firestation
	from deep_dive.fire_stations fss 
	order by  b.geometry <-> fss.geometry
	limit 1
) subq
) 
, 
union_geometries as (
select 
	id_firestation, 
	ST_UNION(geom_firestation) as geom_fire_station, 
	ST_UNION(geom_building) as geom_buildings, 
	COUNT(id_building) as num_buildings
from distance_mapping 
group by id_firestation
)
select * from union_geometries


-- voronoi plot 
with 
voronoi_plot as (
	 select
	 	 ST_VoronoiPolygons(ST_UNION(ST_CENTROID(geometry))) as vd
	 from deep_dive.fire_stations fs2 
)
,
unnest_voronoi as (
	select 
		(ST_DUMP(ST_CollectionExtract(vd))).geom as voronoi_diagrams
	from voronoi_plot
)
, 
limit_to_essen as (
	select 
		ST_INTERSECTION(voronoi_diagrams, t.geometry) as voronoi_diagrams
	from unnest_voronoi, deep_dive.territories t 
	where t.osm_id = 'relation/62713' -- admin border for Essen 

)
select * from limit_to_essen





