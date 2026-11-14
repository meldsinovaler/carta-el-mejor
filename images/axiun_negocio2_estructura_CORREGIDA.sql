-- AXIUN V ORIGINAL -> NEGOCIO 2. Esquema sin datos de pedidos, ventas ni usuarios.
-- Instalar SOLO en un proyecto Supabase nuevo y vacio. No usar en Donde Justo.
-- Preparado a partir de estructura.sql y private.sql, exportaciones de pg_dump.
-- NO incluye la Edge Function login-usuario, cuentas de Auth, catalogo ni imagenes.
-- Este script modifica la base DESTINO. Revisar antes de ejecutarlo.
BEGIN;
SET check_function_bodies = false;
SET client_min_messages = warning;
-- public ya existe en un proyecto Supabase nuevo: NO recrearlo.
CREATE SCHEMA IF NOT EXISTS private;

-- 1. Tablas y secuencias
SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: detalle_ordenes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.detalle_ordenes (
    id bigint NOT NULL,
    orden_id bigint NOT NULL,
    producto_id bigint NOT NULL,
    cantidad integer NOT NULL,
    precio_unitario numeric(10,2) NOT NULL,
    CONSTRAINT detalle_ordenes_cantidad_check CHECK ((cantidad > 0)),
    CONSTRAINT detalle_ordenes_precio_unitario_check CHECK ((precio_unitario > (0)::numeric))
);


--
-- Name: detalle_ordenes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.detalle_ordenes ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.detalle_ordenes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ordenes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ordenes (
    id bigint NOT NULL,
    tipo text NOT NULL,
    numero_mesa integer,
    estado text DEFAULT 'pendiente'::text NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    cerrado_en timestamp with time zone,
    creado_por uuid,
    CONSTRAINT ordenes_check CHECK ((((tipo = 'mesa'::text) AND (numero_mesa > 0)) OR ((tipo = 'llevar'::text) AND (numero_mesa IS NULL)))),
    CONSTRAINT ordenes_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'pagado'::text, 'anulado'::text]))),
    CONSTRAINT ordenes_tipo_check CHECK ((tipo = ANY (ARRAY['mesa'::text, 'llevar'::text])))
);


--
-- Name: ordenes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ordenes ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ordenes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: perfiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.perfiles (
    id uuid NOT NULL,
    usuario text NOT NULL,
    rol text NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    correo_acceso text,
    CONSTRAINT perfiles_rol_check CHECK ((rol = ANY (ARRAY['mesera'::text, 'administrador'::text]))),
    CONSTRAINT perfiles_usuario_check CHECK ((usuario ~ '^[a-z0-9_]{3,30}$'::text))
);


--
-- Name: productos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.productos (
    id bigint NOT NULL,
    nombre text NOT NULL,
    precio numeric(10,2) NOT NULL,
    categoria text NOT NULL,
    imagen_url text,
    activo boolean DEFAULT true NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT productos_precio_check CHECK ((precio > (0)::numeric))
);


--
-- Name: productos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.productos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.productos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: intentos_login; Type: TABLE; Schema: private; Owner: -
--

CREATE TABLE private.intentos_login (
    identificador text NOT NULL,
    intentos integer DEFAULT 0 NOT NULL,
    ventana_inicio timestamp with time zone DEFAULT now() NOT NULL,
    bloqueado_hasta timestamp with time zone
);



-- 2. Funciones privadas
--
-- Name: es_administrador(); Type: FUNCTION; Schema: private; Owner: -
--

CREATE FUNCTION private.es_administrador() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.perfiles
        WHERE id = (SELECT auth.uid())
          AND rol = 'administrador'
    );
$$;


--
-- Name: limites_jornada_2am(text); Type: FUNCTION; Schema: private; Owner: -
--

CREATE FUNCTION private.limites_jornada_2am(p_periodo text) RETURNS TABLE(inicio timestamp with time zone, fin timestamp with time zone)
    LANGUAGE plpgsql STABLE
    SET search_path TO ''
    AS $$
DECLARE
    v_hoy DATE :=
        ((NOW() AT TIME ZONE 'America/Lima')
        - INTERVAL '2 hours')::DATE;
    v_inicio DATE;
BEGIN
    CASE p_periodo
        WHEN 'hoy' THEN
            v_inicio := v_hoy;
        WHEN 'ayer' THEN
            v_inicio := v_hoy - 1;
        WHEN '7' THEN
            v_inicio := v_hoy - 6;
        WHEN 'mes' THEN
            v_inicio := date_trunc('month', v_hoy::timestamp)::DATE;
        WHEN '3' THEN
            v_inicio := (
                date_trunc('month', v_hoy::timestamp)
                - INTERVAL '2 months'
            )::DATE;
        WHEN '6' THEN
            v_inicio := (
                date_trunc('month', v_hoy::timestamp)
                - INTERVAL '5 months'
            )::DATE;
        WHEN 'anio' THEN
            v_inicio := date_trunc('year', v_hoy::timestamp)::DATE;
        WHEN 'todo' THEN
            v_inicio := NULL;
        ELSE
            RAISE EXCEPTION 'Periodo invalido';
    END CASE;

    inicio := CASE
        WHEN v_inicio IS NULL THEN NULL
        ELSE (
            v_inicio::timestamp + INTERVAL '2 hours'
        ) AT TIME ZONE 'America/Lima'
    END;

    fin := CASE
        WHEN p_periodo = 'todo' THEN NULL
        WHEN p_periodo = 'ayer' THEN (
            v_hoy::timestamp + INTERVAL '2 hours'
        ) AT TIME ZONE 'America/Lima'
        ELSE (
            (v_hoy + 1)::timestamp + INTERVAL '2 hours'
        ) AT TIME ZONE 'America/Lima'
    END;

    RETURN NEXT;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;


-- 3. Funciones publicas
--
-- Name: cerrar_orden(bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cerrar_orden(p_orden_id bigint, p_estado text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    -- Comprobar el estado solicitado
    IF p_estado IS NULL
       OR p_estado NOT IN ('pagado', 'anulado') THEN
        RAISE EXCEPTION 'Estado invalido';
    END IF;

    -- Comprobar que sea una mesera autorizada
    IF auth.uid() IS NULL OR NOT EXISTS (
        SELECT 1
        FROM public.perfiles
        WHERE id = auth.uid()
          AND rol = 'mesera'
    ) THEN
        RAISE EXCEPTION 'Usuario no autorizado';
    END IF;

    -- Cerrar únicamente una orden propia y pendiente
    UPDATE public.ordenes
    SET estado = p_estado,
        cerrado_en = NOW()
    WHERE id = p_orden_id
      AND creado_por = auth.uid()
      AND estado = 'pendiente'
      AND EXISTS (
          SELECT 1
          FROM public.detalle_ordenes
          WHERE orden_id = p_orden_id
      );

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Orden no disponible para cerrar';
    END IF;
END;
$$;


--
-- Name: controlar_intento_login(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.controlar_intento_login(p_usuario text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
DECLARE
    v_usuario TEXT;
    v_intentos INTEGER;
BEGIN
    v_usuario := lower(trim(p_usuario));

    IF v_usuario IS NULL
       OR v_usuario !~ '^[a-z0-9_]{3,30}$'
    THEN
        RETURN FALSE;
    END IF;

    -- Evitar que solicitudes simultáneas
    -- eludan el contador
    PERFORM pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(v_usuario, 0)
    );

    INSERT INTO private.intentos_login (
        identificador,
        intentos,
        ventana_inicio,
        bloqueado_hasta
    )
    VALUES (
        v_usuario, 1, now(), NULL
    )
    ON CONFLICT (identificador)
    DO UPDATE SET
        intentos = CASE
            WHEN private.intentos_login.ventana_inicio
                 <= now() - INTERVAL '15 minutes'
            THEN 1
            ELSE private.intentos_login.intentos + 1
        END,
        ventana_inicio = CASE
            WHEN private.intentos_login.ventana_inicio
                 <= now() - INTERVAL '15 minutes'
            THEN now()
            ELSE private.intentos_login.ventana_inicio
        END;

    SELECT intentos
    INTO v_intentos
    FROM private.intentos_login
    WHERE identificador = v_usuario;

    RETURN v_intentos <= 5;
END;
$_$;


--
-- Name: detalle_venta_administrador(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.detalle_venta_administrador(p_pedido_id bigint) RETURNS TABLE(producto text, cantidad integer, precio_unitario numeric, subtotal numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
  IF (SELECT auth.uid()) IS NULL OR NOT (SELECT private.es_administrador()) THEN
    RAISE EXCEPTION 'Acceso no autorizado';
  END IF;
  IF p_pedido_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.ordenes o
    WHERE o.id=p_pedido_id AND o.estado='pagado'
  ) THEN
    RAISE EXCEPTION 'Venta no encontrada';
  END IF;
  RETURN QUERY
  SELECT COALESCE(p.nombre,'Producto no disponible')::TEXT,
         d.cantidad::INTEGER,
         d.precio_unitario::NUMERIC,
         (d.cantidad * d.precio_unitario)::NUMERIC
  FROM public.detalle_ordenes d
  LEFT JOIN public.productos p ON p.id=d.producto_id
  WHERE d.orden_id=p_pedido_id
  ORDER BY d.id;
END;
$$;


--
-- Name: editar_orden(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.editar_orden(p_orden_id bigint, p_items jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_orden BIGINT;
    v_total INTEGER;
    v_distintos INTEGER;
    v_validos INTEGER;
    v_cantidades_ok BOOLEAN;
BEGIN
    -- Verificar la identidad de la mesera
    IF (SELECT auth.uid()) IS NULL
       OR NOT EXISTS (
           SELECT 1
           FROM public.perfiles
           WHERE id = (SELECT auth.uid())
             AND rol = 'mesera'
       ) THEN
        RAISE EXCEPTION 'Usuario no autorizado';
    END IF;

    -- Bloquear la orden mientras se edita
    SELECT id INTO v_orden
    FROM public.ordenes
    WHERE id = p_orden_id
      AND creado_por = (SELECT auth.uid())
      AND estado = 'pendiente'
    FOR UPDATE;

    IF v_orden IS NULL THEN
        RAISE EXCEPTION 'Orden no disponible';
    END IF;

    -- Validar la lista de productos
    IF p_items IS NULL
       OR jsonb_typeof(p_items) <> 'array'
       OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 50
    THEN
        RAISE EXCEPTION 'Lista invalida';
    END IF;

    SELECT
        count(*)::INTEGER,
        count(DISTINCT x.producto_id)::INTEGER,
        coalesce(bool_and(
            x.producto_id IS NOT NULL
            AND x.cantidad BETWEEN 1 AND 99
        ), false)
    INTO v_total, v_distintos, v_cantidades_ok
    FROM jsonb_to_recordset(p_items)
        AS x(producto_id BIGINT, cantidad INTEGER);

    IF v_total <> jsonb_array_length(p_items)
       OR v_total <> v_distintos
       OR NOT v_cantidades_ok THEN
        RAISE EXCEPTION 'Productos invalidos';
    END IF;

    -- Verificar productos disponibles
    SELECT count(*)::INTEGER
    INTO v_validos
    FROM jsonb_to_recordset(p_items)
        AS x(producto_id BIGINT, cantidad INTEGER)
    JOIN public.productos p
        ON p.id = x.producto_id
    WHERE p.activo = TRUE;

    IF v_validos <> v_total THEN
        RAISE EXCEPTION 'Producto no disponible';
    END IF;

    -- Eliminar productos retirados de la orden
    DELETE FROM public.detalle_ordenes d
    WHERE d.orden_id = p_orden_id
      AND NOT EXISTS (
          SELECT 1
          FROM jsonb_to_recordset(p_items)
              AS x(producto_id BIGINT, cantidad INTEGER)
          WHERE x.producto_id = d.producto_id
      );

    -- Actualizar cantidades y agregar productos nuevos
    INSERT INTO public.detalle_ordenes (
        orden_id, producto_id,
        cantidad, precio_unitario
    )
    SELECT
        p_orden_id,
        p.id,
        x.cantidad,
        p.precio
    FROM jsonb_to_recordset(p_items)
        AS x(producto_id BIGINT, cantidad INTEGER)
    JOIN public.productos p
        ON p.id = x.producto_id
    ON CONFLICT (orden_id, producto_id)
    DO UPDATE SET
        cantidad = EXCLUDED.cantidad;
END;
$$;


--
-- Name: historial_ventas(bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.historial_ventas(p_antes_id bigint DEFAULT NULL::bigint, p_limite integer DEFAULT 20) RETURNS TABLE(pedido_id bigint, tipo text, numero_mesa integer, cerrado_en timestamp with time zone, total numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    -- Solo el administrador puede consultar
    IF (SELECT auth.uid()) IS NULL
       OR NOT (SELECT private.es_administrador()) THEN
        RAISE EXCEPTION 'Acceso no autorizado';
    END IF;

    -- Permitir entre 1 y 50 ventas por consulta
    IF p_limite IS NULL
       OR p_limite NOT BETWEEN 1 AND 50 THEN
        RAISE EXCEPTION 'Limite invalido';
    END IF;

    RETURN QUERY
    SELECT
        o.id,
        o.tipo,
        o.numero_mesa,
        o.cerrado_en,
        COALESCE((
            SELECT SUM(d.cantidad * d.precio_unitario)
            FROM public.detalle_ordenes d
            WHERE d.orden_id = o.id
        ), 0)::NUMERIC
    FROM public.ordenes o
    WHERE o.estado = 'pagado'
      AND (
          p_antes_id IS NULL
          OR o.id < p_antes_id
      )
    ORDER BY o.id DESC
    LIMIT p_limite;
END;
$$;


--
-- Name: historial_ventas_ayer(bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.historial_ventas_ayer(p_antes_id bigint DEFAULT NULL::bigint, p_limite integer DEFAULT 21) RETURNS TABLE(pedido_id bigint, tipo text, numero_mesa integer, cerrado_en timestamp with time zone, total numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
  IF (SELECT auth.uid()) IS NULL OR NOT (SELECT private.es_administrador()) THEN
    RAISE EXCEPTION 'Acceso no autorizado';
  END IF;
  IF p_limite IS NULL OR p_limite NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'Límite inválido';
  END IF;
  RETURN QUERY
  SELECT o.id, o.tipo, o.numero_mesa, o.cerrado_en,
         COALESCE((SELECT SUM(d.cantidad * d.precio_unitario)
                   FROM public.detalle_ordenes d WHERE d.orden_id = o.id), 0)::NUMERIC
  FROM public.ordenes o
  WHERE o.estado = 'pagado'
    AND o.cerrado_en >= (( ((NOW() AT TIME ZONE 'America/Lima')::DATE - 1)::TIMESTAMP ) AT TIME ZONE 'America/Lima')
    AND o.cerrado_en <  (( ((NOW() AT TIME ZONE 'America/Lima')::DATE)::TIMESTAMP ) AT TIME ZONE 'America/Lima')
    AND (p_antes_id IS NULL OR o.id < p_antes_id)
  ORDER BY o.id DESC
  LIMIT p_limite;
END;
$$;


--
-- Name: historial_ventas_jornada(text, bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.historial_ventas_jornada(p_periodo text, p_antes_id bigint DEFAULT NULL::bigint, p_limite integer DEFAULT 21) RETURNS TABLE(pedido_id bigint, tipo text, numero_mesa integer, cerrado_en timestamp with time zone, total numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE v_inicio TIMESTAMPTZ; v_fin TIMESTAMPTZ;
BEGIN
  IF (SELECT auth.uid()) IS NULL OR NOT (SELECT private.es_administrador()) THEN
    RAISE EXCEPTION 'Acceso no autorizado';
  END IF;
  IF p_limite IS NULL OR p_limite NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'Limite invalido';
  END IF;
  SELECT r.inicio, r.fin INTO v_inicio, v_fin FROM private.limites_jornada_2am(p_periodo) r;
  RETURN QUERY
  SELECT o.id,o.tipo,o.numero_mesa,o.cerrado_en,
    COALESCE((SELECT SUM(d.cantidad*d.precio_unitario)
      FROM public.detalle_ordenes d WHERE d.orden_id=o.id),0)::NUMERIC
  FROM public.ordenes o
  WHERE o.estado='pagado'
    AND (p_antes_id IS NULL OR o.id<p_antes_id)
    AND (v_inicio IS NULL OR o.cerrado_en >= v_inicio)
    AND (v_fin IS NULL OR o.cerrado_en < v_fin)
  ORDER BY o.id DESC LIMIT p_limite;
END;
$$;


--
-- Name: historial_ventas_periodo(text, bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.historial_ventas_periodo(p_periodo text, p_antes_id bigint DEFAULT NULL::bigint, p_limite integer DEFAULT 20) RETURNS TABLE(pedido_id bigint, tipo text, numero_mesa integer, cerrado_en timestamp with time zone, total numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_hoy DATE;
    v_inicio DATE;
    v_fin DATE;
BEGIN
    IF (SELECT auth.uid()) IS NULL
       OR NOT (SELECT private.es_administrador()) THEN
        RAISE EXCEPTION 'Acceso no autorizado';
    END IF;

    IF p_limite IS NULL
       OR p_limite NOT BETWEEN 1 AND 50 THEN
        RAISE EXCEPTION 'Limite invalido';
    END IF;

    v_hoy := (NOW() AT TIME ZONE 'America/Lima')::DATE;
    v_fin := v_hoy + 1;

    CASE p_periodo
        WHEN 'hoy' THEN v_inicio := v_hoy;
        WHEN '7' THEN v_inicio := v_hoy - 6;
        WHEN 'mes' THEN
            v_inicio := DATE_TRUNC('month', v_hoy)::DATE;
        WHEN '3' THEN
            v_inicio := (
                DATE_TRUNC('month', v_hoy)
                - INTERVAL '2 months'
            )::DATE;
        WHEN '6' THEN
            v_inicio := (
                DATE_TRUNC('month', v_hoy)
                - INTERVAL '5 months'
            )::DATE;
        WHEN 'anio' THEN
            v_inicio := DATE_TRUNC('year', v_hoy)::DATE;
        WHEN 'todo' THEN v_inicio := NULL;
        ELSE RAISE EXCEPTION 'Periodo invalido';
    END CASE;

    RETURN QUERY
    SELECT
        o.id,
        o.tipo,
        o.numero_mesa,
        o.cerrado_en,
        COALESCE((
            SELECT SUM(d.cantidad * d.precio_unitario)
            FROM public.detalle_ordenes d
            WHERE d.orden_id = o.id
        ), 0)
    FROM public.ordenes o
    WHERE o.estado = 'pagado'
      AND o.cerrado_en IS NOT NULL
      AND (p_antes_id IS NULL OR o.id < p_antes_id)
      AND (
          v_inicio IS NULL
          OR o.cerrado_en >= (
              v_inicio::TIMESTAMP AT TIME ZONE 'America/Lima'
          )
      )
      AND o.cerrado_en < (
          v_fin::TIMESTAMP AT TIME ZONE 'America/Lima'
      )
    ORDER BY o.id DESC
    LIMIT p_limite;
END;
$$;


--
-- Name: registrar_orden(text, integer, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.registrar_orden(p_tipo text, p_numero_mesa integer, p_items jsonb) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_usuario UUID;
    v_orden BIGINT;
    v_total INTEGER;
    v_distintos INTEGER;
    v_validos INTEGER;
    v_cantidades_ok BOOLEAN;
BEGIN
    -- Identificar al usuario autenticado
    v_usuario := auth.uid();

    IF v_usuario IS NULL OR NOT EXISTS (
        SELECT 1
        FROM public.perfiles
        WHERE id = v_usuario
          AND rol = 'mesera'
    ) THEN
        RAISE EXCEPTION 'Usuario no autorizado';
    END IF;

    -- Validar si es mesa o para llevar
    IF p_tipo NOT IN ('mesa', 'llevar')
       OR p_tipo IS NULL THEN
        RAISE EXCEPTION 'Tipo de pedido invalido';
    END IF;

    IF (p_tipo = 'mesa'
        AND (p_numero_mesa IS NULL OR p_numero_mesa < 1))
       OR (p_tipo = 'llevar'
        AND p_numero_mesa IS NOT NULL) THEN
        RAISE EXCEPTION 'Numero de mesa invalido';
    END IF;

    -- Validar la lista de productos
    IF p_items IS NULL
       OR jsonb_typeof(p_items) <> 'array'
       OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 50
    THEN
        RAISE EXCEPTION 'Lista de productos invalida';
    END IF;

    SELECT
        count(*)::INTEGER,
        count(DISTINCT x.producto_id)::INTEGER,
        coalesce(bool_and(
            x.producto_id IS NOT NULL
            AND x.cantidad BETWEEN 1 AND 99
        ), false)
    INTO v_total, v_distintos, v_cantidades_ok
    FROM jsonb_to_recordset(p_items)
        AS x(producto_id BIGINT, cantidad INTEGER);

    IF v_total <> jsonb_array_length(p_items)
       OR v_total <> v_distintos
       OR NOT v_cantidades_ok THEN
        RAISE EXCEPTION 'Productos o cantidades invalidos';
    END IF;

    -- Comprobar que todos los productos existan y estén activos
    SELECT count(*)::INTEGER
    INTO v_validos
    FROM jsonb_to_recordset(p_items)
        AS x(producto_id BIGINT, cantidad INTEGER)
    JOIN public.productos p
        ON p.id = x.producto_id
    WHERE p.activo = true;

    IF v_validos <> v_total THEN
        RAISE EXCEPTION 'Hay productos no disponibles';
    END IF;

    -- Crear la orden pendiente
    INSERT INTO public.ordenes (
        tipo, numero_mesa, estado, creado_por
    )
    VALUES (
        p_tipo, p_numero_mesa, 'pendiente', v_usuario
    )
    RETURNING id INTO v_orden;

    -- Guardar productos con precios del catálogo
    INSERT INTO public.detalle_ordenes (
        orden_id, producto_id, cantidad, precio_unitario
    )
    SELECT
        v_orden,
        p.id,
        x.cantidad,
        p.precio
    FROM jsonb_to_recordset(p_items)
        AS x(producto_id BIGINT, cantidad INTEGER)
    JOIN public.productos p
        ON p.id = x.producto_id;

    RETURN v_orden;
END;
$$;


--
-- Name: reiniciar_intentos_login(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reiniciar_intentos_login(p_usuario text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    DELETE FROM private.intentos_login
    WHERE identificador = lower(trim(p_usuario));
END;
$$;


--
-- Name: reporte_productos(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reporte_productos(p_periodo text) RETURNS TABLE(producto_id bigint, producto text, cantidad_vendida bigint, importe_total numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_hoy DATE;
    v_inicio DATE;
    v_fin DATE;
BEGIN
    -- Permitir el acceso solamente al administrador
    IF (SELECT auth.uid()) IS NULL
       OR NOT (SELECT private.es_administrador()) THEN
        RAISE EXCEPTION 'Acceso no autorizado';
    END IF;

    -- Utilizar el calendario peruano
    v_hoy := (NOW() AT TIME ZONE 'America/Lima')::DATE;
    v_fin := v_hoy + 1;

    CASE p_periodo
        WHEN 'hoy' THEN
            v_inicio := v_hoy;
        WHEN '7' THEN
            v_inicio := v_hoy - 6;
        WHEN 'mes' THEN
            v_inicio := DATE_TRUNC('month', v_hoy)::DATE;
        WHEN '3' THEN
            v_inicio := (
                DATE_TRUNC('month', v_hoy)
                - INTERVAL '2 months'
            )::DATE;
        WHEN '6' THEN
            v_inicio := (
                DATE_TRUNC('month', v_hoy)
                - INTERVAL '5 months'
            )::DATE;
        WHEN 'anio' THEN
            v_inicio := DATE_TRUNC('year', v_hoy)::DATE;
        WHEN 'todo' THEN
            v_inicio := NULL;
        ELSE
            RAISE EXCEPTION 'Periodo invalido';
    END CASE;

    -- Calcular productos vendidos
    RETURN QUERY
    SELECT
        p.id,
        p.nombre,
        SUM(d.cantidad)::BIGINT,
        SUM(d.cantidad * d.precio_unitario)
    FROM public.ordenes o
    JOIN public.detalle_ordenes d
        ON d.orden_id = o.id
    JOIN public.productos p
        ON p.id = d.producto_id
    WHERE o.estado = 'pagado'
      AND o.cerrado_en IS NOT NULL
      AND (
          v_inicio IS NULL
          OR o.cerrado_en >= (
              v_inicio::TIMESTAMP
              AT TIME ZONE 'America/Lima'
          )
      )
      AND o.cerrado_en < (
          v_fin::TIMESTAMP
          AT TIME ZONE 'America/Lima'
      )
    GROUP BY p.id, p.nombre
    ORDER BY
        SUM(d.cantidad) DESC,
        p.nombre;
END;
$$;


--
-- Name: reporte_productos_ayer(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reporte_productos_ayer() RETURNS TABLE(producto_id bigint, producto text, cantidad_vendida bigint, importe_total numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
  IF (SELECT auth.uid()) IS NULL OR NOT (SELECT private.es_administrador()) THEN
    RAISE EXCEPTION 'Acceso no autorizado';
  END IF;
  RETURN QUERY
  SELECT p.id, p.nombre,
         SUM(d.cantidad)::BIGINT,
         SUM(d.cantidad * d.precio_unitario)::NUMERIC
  FROM public.ordenes o
  JOIN public.detalle_ordenes d ON d.orden_id = o.id
  JOIN public.productos p ON p.id = d.producto_id
  WHERE o.estado = 'pagado'
    AND o.cerrado_en >= (( ((NOW() AT TIME ZONE 'America/Lima')::DATE - 1)::TIMESTAMP ) AT TIME ZONE 'America/Lima')
    AND o.cerrado_en <  (( ((NOW() AT TIME ZONE 'America/Lima')::DATE)::TIMESTAMP ) AT TIME ZONE 'America/Lima')
  GROUP BY p.id, p.nombre
  ORDER BY SUM(d.cantidad) DESC, p.nombre;
END;
$$;


--
-- Name: reporte_productos_jornada(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reporte_productos_jornada(p_periodo text) RETURNS TABLE(producto_id bigint, producto text, cantidad_vendida bigint, importe_total numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE v_inicio TIMESTAMPTZ; v_fin TIMESTAMPTZ;
BEGIN
  IF (SELECT auth.uid()) IS NULL OR NOT (SELECT private.es_administrador()) THEN
    RAISE EXCEPTION 'Acceso no autorizado';
  END IF;
  SELECT r.inicio, r.fin INTO v_inicio, v_fin FROM private.limites_jornada_2am(p_periodo) r;
  RETURN QUERY
  SELECT p.id, p.nombre, SUM(d.cantidad)::BIGINT,
    SUM(d.cantidad * d.precio_unitario)::NUMERIC
  FROM public.ordenes o
  JOIN public.detalle_ordenes d ON d.orden_id=o.id
  JOIN public.productos p ON p.id=d.producto_id
  WHERE o.estado='pagado'
    AND (v_inicio IS NULL OR o.cerrado_en >= v_inicio)
    AND (v_fin IS NULL OR o.cerrado_en < v_fin)
  GROUP BY p.id,p.nombre
  ORDER BY SUM(d.cantidad) DESC,p.nombre;
END;
$$;


--
-- Name: reporte_ventas(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reporte_ventas(p_periodo text) RETURNS TABLE(pedidos_pagados bigint, ingresos_totales numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_hoy DATE;
    v_inicio DATE;
    v_fin DATE;
BEGIN
    -- Solo puede consultar el administrador
    IF auth.uid() IS NULL
       OR NOT private.es_administrador() THEN
        RAISE EXCEPTION 'Acceso no autorizado';
    END IF;

    -- Fecha actual en Perú
    v_hoy := (NOW() AT TIME ZONE 'America/Lima')::DATE;
    v_fin := v_hoy + 1;

    -- Seleccionar periodo
    CASE p_periodo
        WHEN 'hoy' THEN
            v_inicio := v_hoy;
        WHEN '7' THEN
            v_inicio := v_hoy - 6;
        WHEN 'mes' THEN
            v_inicio := DATE_TRUNC('month', v_hoy)::DATE;
        WHEN '3' THEN
            v_inicio := (
                DATE_TRUNC('month', v_hoy)
                - INTERVAL '2 months'
            )::DATE;
        WHEN '6' THEN
            v_inicio := (
                DATE_TRUNC('month', v_hoy)
                - INTERVAL '5 months'
            )::DATE;
        WHEN 'anio' THEN
            v_inicio := DATE_TRUNC('year', v_hoy)::DATE;
        WHEN 'todo' THEN
            v_inicio := NULL;
        ELSE
            RAISE EXCEPTION 'Periodo invalido';
    END CASE;

    RETURN QUERY
    SELECT
        COUNT(DISTINCT o.id),
        COALESCE(
            SUM(d.cantidad * d.precio_unitario),
            0
        )
    FROM public.ordenes o
    JOIN public.detalle_ordenes d
        ON d.orden_id = o.id
    WHERE o.estado = 'pagado'
      AND o.cerrado_en IS NOT NULL
      AND (
          v_inicio IS NULL
          OR o.cerrado_en >= (
              v_inicio::TIMESTAMP AT TIME ZONE 'America/Lima'
          )
      )
      AND o.cerrado_en < (
          v_fin::TIMESTAMP AT TIME ZONE 'America/Lima'
      );
END;
$$;


--
-- Name: reporte_ventas_ayer(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reporte_ventas_ayer() RETURNS TABLE(pedidos_pagados bigint, ingresos_totales numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
  IF (SELECT auth.uid()) IS NULL OR NOT (SELECT private.es_administrador()) THEN
    RAISE EXCEPTION 'Acceso no autorizado';
  END IF;
  RETURN QUERY
  SELECT COUNT(o.id)::BIGINT,
         COALESCE(SUM((SELECT SUM(d.cantidad * d.precio_unitario)
                       FROM public.detalle_ordenes d WHERE d.orden_id = o.id)), 0)::NUMERIC
  FROM public.ordenes o
  WHERE o.estado = 'pagado'
    AND o.cerrado_en >= (( ((NOW() AT TIME ZONE 'America/Lima')::DATE - 1)::TIMESTAMP ) AT TIME ZONE 'America/Lima')
    AND o.cerrado_en <  (( ((NOW() AT TIME ZONE 'America/Lima')::DATE)::TIMESTAMP ) AT TIME ZONE 'America/Lima');
END;
$$;


--
-- Name: reporte_ventas_jornada(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reporte_ventas_jornada(p_periodo text) RETURNS TABLE(pedidos_pagados bigint, ingresos_totales numeric)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE v_inicio TIMESTAMPTZ; v_fin TIMESTAMPTZ;
BEGIN
  IF (SELECT auth.uid()) IS NULL OR NOT (SELECT private.es_administrador()) THEN
    RAISE EXCEPTION 'Acceso no autorizado';
  END IF;
  SELECT r.inicio, r.fin INTO v_inicio, v_fin FROM private.limites_jornada_2am(p_periodo) r;
  RETURN QUERY
  SELECT COUNT(o.id)::BIGINT,
    COALESCE(SUM((SELECT SUM(d.cantidad * d.precio_unitario)
                  FROM public.detalle_ordenes d WHERE d.orden_id = o.id)),0)::NUMERIC
  FROM public.ordenes o
  WHERE o.estado='pagado'
    AND (v_inicio IS NULL OR o.cerrado_en >= v_inicio)
    AND (v_fin IS NULL OR o.cerrado_en < v_fin);
END;
$$;



-- 4. Restricciones y politicas
--
-- Name: intentos_login intentos_login_pkey; Type: CONSTRAINT; Schema: private; Owner: -
--

ALTER TABLE ONLY private.intentos_login
    ADD CONSTRAINT intentos_login_pkey PRIMARY KEY (identificador);


--
-- Name: intentos_login; Type: ROW SECURITY; Schema: private; Owner: -
--

ALTER TABLE private.intentos_login ENABLE ROW LEVEL SECURITY;


--
-- Name: detalle_ordenes detalle_ordenes_orden_id_producto_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.detalle_ordenes
    ADD CONSTRAINT detalle_ordenes_orden_id_producto_id_key UNIQUE (orden_id, producto_id);


--
-- Name: detalle_ordenes detalle_ordenes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.detalle_ordenes
    ADD CONSTRAINT detalle_ordenes_pkey PRIMARY KEY (id);


--
-- Name: ordenes ordenes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ordenes
    ADD CONSTRAINT ordenes_pkey PRIMARY KEY (id);


--
-- Name: perfiles perfiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perfiles
    ADD CONSTRAINT perfiles_pkey PRIMARY KEY (id);


--
-- Name: perfiles perfiles_usuario_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perfiles
    ADD CONSTRAINT perfiles_usuario_key UNIQUE (usuario);


--
-- Name: productos productos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.productos
    ADD CONSTRAINT productos_pkey PRIMARY KEY (id);


--
-- Name: detalle_ordenes detalle_ordenes_orden_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.detalle_ordenes
    ADD CONSTRAINT detalle_ordenes_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES public.ordenes(id) ON DELETE CASCADE;


--
-- Name: detalle_ordenes detalle_ordenes_producto_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.detalle_ordenes
    ADD CONSTRAINT detalle_ordenes_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id);


--
-- Name: ordenes ordenes_creado_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ordenes
    ADD CONSTRAINT ordenes_creado_por_fkey FOREIGN KEY (creado_por) REFERENCES auth.users(id);


--
-- Name: perfiles perfiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.perfiles
    ADD CONSTRAINT perfiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: ordenes Administradores consultan anulados; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Administradores consultan anulados" ON public.ordenes FOR SELECT TO authenticated USING (((estado = 'anulado'::text) AND (EXISTS ( SELECT 1
   FROM public.perfiles
  WHERE ((perfiles.id = ( SELECT auth.uid() AS uid)) AND (perfiles.rol = 'administrador'::text))))));


--
-- Name: productos Consultar catalogo; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Consultar catalogo" ON public.productos FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.perfiles
  WHERE (perfiles.id = ( SELECT auth.uid() AS uid)))));


--
-- Name: detalle_ordenes Consultar detalles autorizados; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Consultar detalles autorizados" ON public.detalle_ordenes FOR SELECT TO authenticated USING ((EXISTS ( SELECT 1
   FROM public.ordenes o
  WHERE (o.id = detalle_ordenes.orden_id))));


--
-- Name: ordenes Consultar ordenes segun rol; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Consultar ordenes segun rol" ON public.ordenes FOR SELECT TO authenticated USING ((((estado = 'pendiente'::text) AND (creado_por = ( SELECT auth.uid() AS uid)) AND (EXISTS ( SELECT 1
   FROM public.perfiles
  WHERE ((perfiles.id = ( SELECT auth.uid() AS uid)) AND (perfiles.rol = 'mesera'::text))))) OR ((estado = 'pagado'::text) AND ( SELECT private.es_administrador() AS es_administrador))));


--
-- Name: perfiles Consultar perfil propio; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Consultar perfil propio" ON public.perfiles FOR SELECT TO authenticated USING ((id = ( SELECT auth.uid() AS uid)));


--
-- Name: detalle_ordenes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.detalle_ordenes ENABLE ROW LEVEL SECURITY;

--
-- Name: ordenes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ordenes ENABLE ROW LEVEL SECURITY;

--
-- Name: perfiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.perfiles ENABLE ROW LEVEL SECURITY;

--
-- Name: productos; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.productos ENABLE ROW LEVEL SECURITY;


-- Permisos minimos para que la API de Supabase pueda consultar mediante RLS.
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT SELECT ON TABLE public.productos, public.perfiles, public.ordenes, public.detalle_ordenes TO authenticated;
-- RLS aplica a las cuatro tablas; la escritura de pedidos se hace mediante RPC SECURITY DEFINER.
-- Revocar solo funciones migradas, sin alterar funciones ajenas del proyecto.
DO $guard$ DECLARE f record; BEGIN
  FOR f IN SELECT p.oid::regprocedure AS signature
           FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public' AND p.proname IN (
             'cerrar_orden','controlar_intento_login','detalle_venta_administrador',
             'editar_orden','historial_ventas','historial_ventas_ayer',
             'historial_ventas_jornada','historial_ventas_periodo',
             'registrar_orden','reiniciar_intentos_login','reporte_productos',
             'reporte_productos_ayer','reporte_productos_jornada',
             'reporte_ventas','reporte_ventas_ayer','reporte_ventas_jornada')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated',f.signature);
  END LOOP;
END $guard$;
GRANT EXECUTE ON FUNCTION public.registrar_orden(text, integer, jsonb), public.editar_orden(bigint, jsonb), public.cerrar_orden(bigint, text), public.historial_ventas(bigint, integer), public.historial_ventas_ayer(bigint, integer), public.historial_ventas_jornada(text, bigint, integer), public.historial_ventas_periodo(text, bigint, integer), public.detalle_venta_administrador(bigint), public.reporte_productos(text), public.reporte_productos_ayer(), public.reporte_productos_jornada(text), public.reporte_ventas(text), public.reporte_ventas_ayer(), public.reporte_ventas_jornada(text) TO authenticated;
-- La Edge Function debe invocar estas RPC con su service_role, nunca desde el cliente.
GRANT EXECUTE ON FUNCTION public.controlar_intento_login(text), public.reiniciar_intentos_login(text) TO service_role;
-- Las operaciones de bloqueo de login se usan desde la Edge Function con privilegios de servidor.
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon, authenticated;
-- Permiso especifico para las politicas de SELECT que comprueban rol de administrador.
GRANT USAGE ON SCHEMA private TO authenticated;
GRANT EXECUTE ON FUNCTION private.es_administrador() TO authenticated;
-- Evitar exposicion accidental de tabla de intentos.
REVOKE ALL ON ALL TABLES IN SCHEMA private FROM PUBLIC, anon, authenticated;
COMMIT;
