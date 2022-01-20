-- example 1 
select 
	b.osm_id as id_building, 
	b.geometry
from deep_dive.building b
inner join deep_dive.landuse l
ON ST_WITHIN(b.geometry, l.geometry) and l.landuse = 'retail' 



-- example 2
select 
	h.osm_id as id_highway, 
	h.geometry 
from deep_dive.highway h
inner join deep_dive.waterway w
ON ST_INTERSECTS(h.geometry, w.geometry)
and h.highway in ('motorway', 'trunk', 'primary', 'secondary', 'tertiary', 'residential')

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
	 	 ST_VoronoiPolygons(ST_UNION(ST_CENTROID(geometry))) as voronoi_diagrams
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



-- Spatial clustering
select 
	cid, 
	ST_Collect(geometry) as cluster_geom
	--array_agg(osm_id) AS ids_in_cluster 
	from (
    select 	osm_id, 
    		ST_ClusterDBSCAN(geometry, eps := 200, minpoints := 5) over () as cid,
    		geometry
    from deep_dive.building b where geometrytype(geometry) = 'POLYGON') sq
group by cid
having cid is not null


-- openspaces 
with 
suitable_landuses as (
	select 
		osm_id,
		geometry, 
		ST_AREA(geometry) as area_geometry_m2, 
		landuse
	from deep_dive.landuse
	where 	landuse in ('commercial', 'retail', 'industrial', 
							  'meadow', 'brownfield', 'greenfield', 
							  'grass', 'farmland')	
			and ST_AREA(geometry) > 0
)
,
unsuitable_locations as (
	select 
		osm_id,
		geometry, 
		ST_AREA(geometry) as area_geometry_m2, 
		landuse
	from deep_dive.landuse
	where landuse in ('basin', 'reservoir', 'quarry', 
					  'landfill', 'military', 'depot', 'allotments', 'construction',
                       'railway', 'forest', 'cemeterey', 'residential', 'winter_sports', 
                       'recreation_ground')
)
,
unusable_land as (
	select 
		b.osm_id, 
		geometry, 
		'building' as reason_unusable
	from deep_dive.building b
	union all 
	select 
		osm_id, 
		geometry, 
		'landuse_unusable_' || landuse as reason_unusable 
	from unsuitable_locations
	union all
	select 
		osm_id, 
		geometry, 
		'waterway' as reason_unusable 
	from deep_dive.waterway w 
	union all 
	select 
		osm_id, 
		geometry, 
		'highway_' || highway as reason_unusable 
	from deep_dive.highway h 
	where highway in ('primary', 'secondary', 'tertiary', 'residential', 'service')
)
, 
unusable_land_combined as (
	select 
		sl.osm_id, 
		ST_UNION(ST_BUFFER(subq.geometry, 10)) as unusable_land
	from suitable_landuses sl
	cross join lateral ( 
		select 
			geometry
		from unusable_land ul
		where st_intersects(sl.geometry, ul.geometry)
	) as subq
	group by sl.osm_id
)
,
diff_usable_land as (
	select 
		sl.osm_id,
		ST_DIFFERENCE(sl.geometry, ul.unusable_land) as geoms_usable
	from suitable_landuses sl
	left join unusable_land_combined ul
	using (osm_id)
	where geometrytype(ST_DIFFERENCE(sl.geometry, ul.unusable_land)) != 'POLYGON EMPTY'
)
, 
unnest_multipolygons as (
	select 
		osm_id, 
		(ST_DUMP(geoms_usable)).geom as geoms_usable
	from diff_usable_land
)
,
filter_usable_area as ( 
	select 
		osm_id, 
		geoms_usable, 
		ST_AREA(geoms_usable) as area_usable_m2
	from unnest_multipolygons
	where ST_AREA(geoms_usable) > 300
)
select * from filter_usable_area order by area_usable_m2 desc


-- spatial clustering
select 
	cid, 
	ST_Collect(geometry) as cluster_geom
	--array_agg(osm_id) AS ids_in_cluster 
	from (
    select osm_id, ST_ClusterDBSCAN(geometry, eps := 100, minpoints := 5) over () as cid, geometry
    from deep_dive.building b where geometrytype(geometry) = 'POLYGON') sq
group by cid
having cid is not null



